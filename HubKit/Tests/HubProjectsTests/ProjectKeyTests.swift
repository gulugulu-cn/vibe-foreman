import XCTest
@testable import HubProjects

/// 项目身份。这一组里第一条是安全测试，不是整洁性测试。
final class ProjectKeyTests: XCTestCase {

    private func project(_ name: String, _ path: String) -> Project {
        Project(name: name, path: path)
    }

    /// **同名不同路径的项目必须写进不同文件。**
    ///
    /// 只用项目名做文件名的话，`~/code/a/api` 和 `~/code/b/api` 共用一个 `.env`，
    /// 于是项目 A 的会话直接拿到项目 B 的密钥。这是安全事故，不是显示问题。
    /// 而 `api` / `server` / `web` / `admin` 这种重名在真实机器上到处都是。
    func testSameNameDifferentPathGetDifferentFiles() {
        let a = project("api", "~/code/a/api")
        let b = project("api", "~/code/b/api")
        XCTAssertNotEqual(ProjectKey.envFileName(for: a), ProjectKey.envFileName(for: b))
    }

    /// yaml 里写 `~/x` 和写 `/Users/xxx/x` 是同一个项目，绑定必须命中同一条。
    /// 不成立的话，用户在 yaml 里把 `~` 展开一下，全部密钥绑定就静默失效了。
    func testTildeAndExpandedPathAreTheSameProject() {
        let home = NSString(string: "~").expandingTildeInPath
        XCTAssertEqual(
            ProjectKey.key(forPath: "~/Documents/code/hj-admin"),
            ProjectKey.key(forPath: "\(home)/Documents/code/hj-admin")
        )
    }

    /// 结尾多一个斜杠不该变成另一个项目。
    func testTrailingSlashIsNormalized() {
        XCTAssertEqual(
            ProjectKey.key(forPath: "~/code/x/"),
            ProjectKey.key(forPath: "~/code/x")
        )
        // 但根目录的那个 `/` 不能被削掉。
        XCTAssertEqual(ProjectKey.key(forPath: "/"), "/")
    }

    /// 同一个项目每次必须算出同一个文件名。变一次就留下一个孤儿文件，
    /// 而孤儿文件里装的是真密钥，`reconcile` 又认不出它该不该删。
    func testFileNameIsStable() {
        let p = project("hj-admin", "~/Documents/code/hj-admin")
        XCTAssertEqual(ProjectKey.envFileName(for: p), ProjectKey.envFileName(for: p))
    }

    /// 中文名会被削成空，靠哈希区分。**不能回落成路径** ——
    /// 那会把用户的绝对路径写进文件名。
    func testNonASCIINameFallsBackWithoutLeakingPath() {
        let p = project("后台管理", "~/Documents/code/houtai")
        let name = ProjectKey.envFileName(for: p)
        XCTAssertTrue(name.hasPrefix("project-"), name)
        XCTAssertFalse(name.contains("Users"), "文件名里出现了路径：\(name)")
        XCTAssertTrue(ProjectKey.looksLikeGeneratedEnvFile(name))
    }

    func testSlugSanitizesSeparatorsAndCase() {
        XCTAssertEqual(ProjectKey.slug("My Project v2"), "my-project-v2")
        XCTAssertEqual(ProjectKey.slug("a///b"), "a-b")
        XCTAssertEqual(ProjectKey.slug("--x--"), "x")
        XCTAssertEqual(ProjectKey.slug("_keep_"), "_keep_")
    }

    /// `reconcile` 只敢删这个形状的文件。判宽了会删掉用户自己放进去的东西，
    /// 判窄了会让自己生成的孤儿文件永远清不掉（里面装着真密钥）。
    func testGeneratedFileRecognition() {
        XCTAssertTrue(ProjectKey.looksLikeGeneratedEnvFile("hj-admin-9f3a1c8d.env"))
        XCTAssertTrue(ProjectKey.looksLikeGeneratedEnvFile("project-00000000.env"))
        XCTAssertTrue(ProjectKey.looksLikeGeneratedEnvFile("_x_-abcdef01.env"))

        XCTAssertFalse(ProjectKey.looksLikeGeneratedEnvFile("mine.env"), "用户自己的文件被认成了我们的")
        XCTAssertFalse(ProjectKey.looksLikeGeneratedEnvFile("hj-admin.env"))
        XCTAssertFalse(ProjectKey.looksLikeGeneratedEnvFile("hj-admin-9f3a1c8.env"))   // 7 位
        XCTAssertFalse(ProjectKey.looksLikeGeneratedEnvFile("hj-admin-9f3a1c8dz.env")) // 9 位
        XCTAssertFalse(ProjectKey.looksLikeGeneratedEnvFile("HJ-ADMIN-9F3A1C8D.ENV"))
        XCTAssertFalse(ProjectKey.looksLikeGeneratedEnvFile("hj-admin-9f3a1c8d.env.bak"))
    }
}

/// 恢复码。抄错一个字符就永久打不开，所以容错是功能的一部分。
final class Base32Tests: XCTestCase {

    func testRoundTripFor32Bytes() {
        let key = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
        let code = Base32.encode(key)
        XCTAssertEqual(Base32.decode(code), key)
    }

    /// 用户是从纸上抄回来的：分组的 `-` 会被带进来，大小写会写错，
    /// 中间可能夹空格或换行。这些都必须能吃下。
    func testDecodeToleratesHumanTranscription() {
        let key = Data(repeating: 0x5A, count: 32)
        let code = Base32.encode(key)
        XCTAssertEqual(Base32.decode(code.lowercased()), key)
        XCTAssertEqual(Base32.decode(code.replacingOccurrences(of: "-", with: " ")), key)
        XCTAssertEqual(Base32.decode(code.replacingOccurrences(of: "-", with: "\n")), key)
    }

    /// `0` 和 `1` 不是合法的 base32 字符，出现在这里只可能是把 `O`/`I` 抄错了。
    /// 纠正它没有歧义，而报「恢复码无效」会让用户完全无从下手。
    func testDecodeFixesZeroAndOne() {
        let withO = "OIOI-OIOI"
        XCTAssertEqual(Base32.decode("0101-0101"), Base32.decode(withO))
    }

    func testRejectsGarbage() {
        XCTAssertNil(Base32.decode("这不是恢复码"))
        XCTAssertNil(Base32.decode("ABCD-EF89"))   // 8/9 不在字母表里
    }

    /// 分组只是为了好抄，不该改变内容。
    func testGroupingIsCosmetic() {
        let key = Data(repeating: 0xC3, count: 32)
        XCTAssertEqual(Base32.decode(Base32.encode(key, grouped: false)), key)
        XCTAssertEqual(
            Base32.encode(key, grouped: true).replacingOccurrences(of: "-", with: ""),
            Base32.encode(key, grouped: false)
        )
    }
}
