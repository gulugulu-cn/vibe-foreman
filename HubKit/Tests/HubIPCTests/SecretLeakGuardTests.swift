import XCTest
@testable import HubIPC

/// 密钥泄漏闸。
///
/// 这一组里**判宽的那几条比判窄的更重要**：漏拦一次是少了一层保护，
/// 误拦一次是正常开发被莫名其妙挡住，而用户对后者的容忍度是零 ——
/// 他会直接把整个功能关掉，然后连漏拦的那层也没了。
final class SecretLeakGuardTests: XCTestCase {

    private var home: URL!
    private var envDir: URL { home.appendingPathComponent(".vibe-foreman/env/by-project") }
    private let secretValue = "cli_a1b2c3d4e5f6g7h8"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
        try """
        # Vibe Foreman 生成
        export FEISHU_APP_SECRET='\(secretValue)'
        export SHORT='abc'
        export PEM='-----BEGIN KEY-----
        MIIEvQIBADANBg
        -----END KEY-----'
        """.write(to: envDir.appendingPathComponent("demo-00000001.env"),
                  atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func inspect(_ tool: String, _ input: [String: Any], cwd: String = "/tmp")
        -> SecretLeakGuard.Finding? {
        SecretLeakGuard.inspect(toolName: tool, input: input, cwd: cwd, home: home)
    }

    // MARK: - 值级拦截

    /// 把真实的密钥值写进文件 —— 这就是「AI 乱提交密钥」最常见的形态。
    /// 它看起来完全无害（Write 一个配置文件），任何基于"这条命令危不危险"的
    /// 判断都拦不住，唯一可靠的信号是内容里出现了真实值。
    func testWritingASecretValueIntoAFileIsBlocked() {
        let finding = inspect("Write", [
            "file_path": "/tmp/p/config.ts",
            "content": "export const appSecret = '\(secretValue)'",
        ])
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.reason.contains("FEISHU_APP_SECRET") == true)
        // 拒绝理由必须给出正确做法，否则它只会换个写法再试一次。
        XCTAssertTrue(finding?.reason.contains("source") == true)
    }

    /// 嵌套结构里也要看。只看顶层的话，把值放进 MultiEdit 的数组里就绕过去了。
    func testNestedInputIsScanned() {
        XCTAssertNotNil(inspect("MultiEdit", [
            "file_path": "/tmp/p/a.ts",
            "edits": [["old_string": "x", "new_string": "token = \"\(secretValue)\""]],
        ]))
    }

    /// 命令行里内联密钥也拦 —— `curl -H "Authorization: Bearer <真值>"` 这种。
    func testInlineSecretInCommandIsBlocked() {
        XCTAssertNotNil(inspect("Bash", [
            "command": "curl -H 'Authorization: Bearer \(secretValue)' https://open.feishu.cn"
        ]))
    }

    /// **约定的用法必须放行。** `source` 那条命令里只有路径，没有值。
    /// 这条要是红了，说明整个功能的正常流程被自己堵死了。
    func testTheDocumentedSourceCommandIsAllowed() {
        XCTAssertNil(inspect("Bash", [
            "command": "set -a; source '\(envDir.path)/demo-00000001.env'; set +a; go test ./..."
        ]))
    }

    /// 引用环境变量名是**鼓励**的做法，不能拦。
    func testReferencingTheVariableIsAllowed() {
        XCTAssertNil(inspect("Bash", ["command": "curl -H \"Authorization: Bearer $FEISHU_APP_SECRET\""]))
        XCTAssertNil(inspect("Write", [
            "file_path": "/tmp/p/a.go",
            "content": "secret := os.Getenv(\"FEISHU_APP_SECRET\")",
        ]))
    }

    /// **太短的值不参与匹配。** `abc`、`true`、`test` 这种会命中一切，
    /// 一旦有人往密钥库里存了个短值，全项目的正常编辑都会被拦。
    func testShortValuesNeverMatch() {
        XCTAssertNil(inspect("Write", ["file_path": "/tmp/a.txt", "content": "abc def"]))
    }

    /// 多行值（PEM）同样要认出来。
    func testMultilineValueIsMatched() {
        XCTAssertNotNil(inspect("Write", [
            "file_path": "/tmp/key.pem",
            "content": "-----BEGIN KEY-----\nMIIEvQIBADANBg\n-----END KEY-----",
        ]))
    }

    // MARK: - 开关

    func testGuardCanBeTurnedOff() throws {
        try Data(#"{"enabled":false}"#.utf8)
            .write(to: home.appendingPathComponent(".vibe-foreman/guard.json"))
        XCTAssertNil(inspect("Write", ["file_path": "/tmp/a", "content": secretValue]))
    }

    /// 文件不存在 = 开着。一个保护性的默认值不该依赖某个文件存在。
    func testGuardIsOnWhenConfigMissing() {
        XCTAssertTrue(SecretLeakGuard.isEnabled(home: home))
    }

    // MARK: - 文件名判断

    func testSecretFileNames() {
        for name in [".env", ".env.local", "/a/b/.env.production", "id_rsa",
                     "certs/server.pem", "credentials.json", ".npmrc"] {
            XCTAssertTrue(SecretLeakGuard.looksLikeSecretFile(name), name)
        }
    }

    /// **模板文件必须放行。** `.env.example` 是给人看的骨架，提交它正是正确做法。
    /// 拦下来只会让人把整个功能关掉。
    func testTemplateFilesAreNotSecretFiles() {
        for name in [".env.example", ".env.template", ".env.sample", "config.pem.example"] {
            XCTAssertFalse(SecretLeakGuard.looksLikeSecretFile(name), name)
        }
    }

    func testOrdinaryFilesAreNotSecretFiles() {
        for name in ["README.md", "main.go", "env.ts", "environment.ts", "package.json"] {
            XCTAssertFalse(SecretLeakGuard.looksLikeSecretFile(name), name)
        }
    }

    // MARK: - 解析

    /// 只认自己写出来的格式。解析器判宽了会把注释里的片段当成值，然后到处误伤。
    func testParserOnlyTakesExportedSingleQuotedValues() {
        let secrets = SecretLeakGuard.parse("""
        # export FAKE='注释里的不算'
        export REAL='0123456789abcdef'
        KEY_WITHOUT_EXPORT='0123456789abcdef'
        export DOUBLE="0123456789abcdef"
        """, file: "/x.env")
        XCTAssertEqual(secrets.map(\.key), ["REAL"])
    }

    // MARK: - git 参数

    func testExplicitAddPathsIgnoresFlagsAndStopsAtPipes() {
        XCTAssertEqual(
            SecretLeakGuard.explicitAddPaths("git add -f src/a.ts .env && git commit -m x"),
            ["src/a.ts", ".env"]
        )
        XCTAssertEqual(SecretLeakGuard.explicitAddPaths("git add 'my file.ts'"), ["my", "file.ts"])
    }

    /// 不是 git add/commit 的命令一个字都别多查 —— 那要起一个 git 子进程，
    /// 而这道闸挂在**每一次**工具调用前面。
    func testNonGitCommandsSkipTheRepositoryScan() {
        XCTAssertTrue(SecretLeakGuard.filesEnteringTheRepository(
            command: "ls -la", cwd: "/tmp").isEmpty)
        XCTAssertTrue(SecretLeakGuard.filesEnteringTheRepository(
            command: "git status", cwd: "/tmp").isEmpty)
    }

    // MARK: - 真的 git 仓库

    /// 造一个真仓库，因为 git 那条路是起子进程跑出来的，
    /// mock 掉就等于没测 —— 而它恰恰是最容易在别人机器上表现不一样的一段。
    private func makeRepo() throws -> String {
        let repo = home.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q"],
                     ["config", "user.email", "t@example.com"],
                     ["config", "user.name", "t"]] {
            _ = SecretLeakGuard.git(args, cwd: repo.path)
        }
        return repo.path
    }

    /// **`git add .` 把 .env 一起提了** —— 这就是 AI 时代最贵的那个事故。
    /// 每一步单看都正常，所以只能靠"这次提交会带进去哪些文件"来判断。
    func testGitAddAllCatchesAnEnvFile() throws {
        let repo = try makeRepo()
        try "SOME=thing".write(toFile: repo + "/.env", atomically: true, encoding: .utf8)

        let finding = inspect("Bash", ["command": "git add ."], cwd: repo)
        XCTAssertNotNil(finding, "git add . 把 .env 带进去了却没拦")
        XCTAssertTrue(finding?.reason.contains(".gitignore") == true, "没告诉用户该怎么办")
    }

    /// 文件名看不出问题，但内容里有真实密钥 —— 靠值匹配兜住。
    func testGitAddCatchesASecretHiddenInAnOrdinaryFile() throws {
        let repo = try makeRepo()
        try "const token = '\(secretValue)'"
            .write(toFile: repo + "/config.ts", atomically: true, encoding: .utf8)

        let finding = inspect("Bash", ["command": "git add config.ts"], cwd: repo)
        XCTAssertTrue(finding?.reason.contains("FEISHU_APP_SECRET") == true,
                      "普通文件里藏的密钥没被认出来：\(String(describing: finding))")
    }

    /// **干净的提交必须放行。** 这条是整组里最该盯的 ——
    /// 误拦一次正常提交，用户就会把整个功能关掉。
    func testOrdinaryCommitIsAllowed() throws {
        let repo = try makeRepo()
        try "# hello".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        _ = SecretLeakGuard.git(["add", "README.md"], cwd: repo)

        XCTAssertNil(inspect("Bash", ["command": "git commit -m 'docs: 加个说明'"], cwd: repo))
        XCTAssertNil(inspect("Bash", ["command": "git add README.md"], cwd: repo))
    }

    /// 模板文件照常提交。
    func testCommittingAnExampleEnvIsAllowed() throws {
        let repo = try makeRepo()
        try "FEISHU_APP_SECRET=\n".write(toFile: repo + "/.env.example",
                                          atomically: true, encoding: .utf8)
        XCTAssertNil(inspect("Bash", ["command": "git add .env.example"], cwd: repo))
    }

    /// 已经暂存好了再 commit，同样要拦 —— 不然 `git add .env && git commit` 的
    /// 第二步就成了绕过路径。
    func testStagedSecretIsCaughtAtCommitTime() throws {
        let repo = try makeRepo()
        try "SOME=thing".write(toFile: repo + "/.env", atomically: true, encoding: .utf8)
        _ = SecretLeakGuard.git(["add", "-f", ".env"], cwd: repo)

        XCTAssertNotNil(inspect("Bash", ["command": "git commit -m wip"], cwd: repo))
    }

    /// 不在 git 仓库里就什么都别做（fail-open）。
    func testOutsideARepositoryNothingHappens() {
        XCTAssertNil(inspect("Bash", ["command": "git add ."], cwd: home.path))
    }
}
