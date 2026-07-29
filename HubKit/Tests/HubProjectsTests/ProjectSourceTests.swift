import XCTest
@testable import HubProjects

/// 守 projects.yaml 这条数据链路。
///
/// 背景是一次真实事故：主窗口三个页面全空。根因不是界面没做，而是
/// **app 读的 projects.yaml 和脚本维护的那份不是同一个文件**，
/// 且它读到的那份是坏的（`projects: []` 后面跟着 117 条内容），
/// 解析器静默返回空数组。
final class ProjectSourceTests: XCTestCase {

    // MARK: - 坏文件

    /// `projects: []` 后面跟着真实条目 —— 旧版写下空数组标记，
    /// 后来的追加逻辑又往文件尾巴上加内容，产出的就是这种文件。
    ///
    /// 原解析器判的是 `trimmed == "projects:"`，`projects: []` 完全不匹配，
    /// 于是后面所有条目被静默忽略。
    func testEmptyArrayMarkerDoesNotSwallowEntries() {
        let yaml = """
        # Claude Hub 项目清单
        scan_dirs:
        - ~/Documents/code

        projects: []

          - name: claude-hub
            path: /Users/dev/Documents/code/claude-hub

          - name: go-wechat
            path: /Users/dev/Documents/code/go-wechat
        """
        let projects = ProjectYAML.parse(yaml)
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects.map(\.name), ["claude-hub", "go-wechat"])
    }

    /// 其它几种"空值"写法同样不能吃掉后面的条目。
    func testOtherEmptyMarkersAlsoParse() {
        for marker in ["[]", "~", "null", "{}"] {
            let yaml = """
            projects: \(marker)
              - name: demo
                path: /tmp/demo
            """
            XCTAssertEqual(
                ProjectYAML.parse(yaml).count, 1,
                "`projects: \(marker)` 后面的条目被吃掉了"
            )
        }
    }

    /// 正常写法不能被上面的放宽改坏。
    func testCanonicalFormStillParses() {
        let yaml = """
        projects:
          - name: acme-erp
            aliases: [acme-admin, erp, 后台]
            path: ~/Documents/code/acme-admin
            description: "示例管理后台"
            tags: [vue, gin]
        """
        let projects = ProjectYAML.parse(yaml)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "acme-erp")
        XCTAssertEqual(projects[0].aliases, ["acme-admin", "erp", "后台"])
        XCTAssertEqual(projects[0].description, "示例管理后台")
        XCTAssertEqual(projects[0].tags, ["vue", "gin"])
    }

    /// 别的顶层段落不能被当成项目段。
    func testOtherTopLevelSectionsAreSkipped() {
        let yaml = """
        scan_dirs:
          - name: 这不是项目
            path: /tmp/nope
        projects:
          - name: real
            path: /tmp/real
        """
        let projects = ProjectYAML.parse(yaml)
        XCTAssertEqual(projects.map(\.name), ["real"])
    }

    // MARK: - 解析失败要能被看见

    /// 文件里明明有条目却一条都没解析出来时，必须给出诊断。
    /// 静默返回空数组正是这次排查花掉最多时间的原因。
    func testBrokenFileProducesDiagnostic() {
        // 项目段整个缺失，但下面有 name 条目。
        let yaml = """
        scan_dirs:
          - ~/code
        somethingelse:
          - name: orphan
            path: /tmp/orphan
        """
        let outcome = ProjectYAML.analyze(yaml)
        XCTAssertTrue(outcome.projects.isEmpty)
        XCTAssertTrue(outcome.looksBroken)
        XCTAssertNotNil(outcome.diagnostic)
    }

    /// 真的就是没有项目（不是格式坏了）时不该报错。
    func testGenuinelyEmptyFileIsNotFlaggedAsBroken() {
        let outcome = ProjectYAML.analyze("projects:\n")
        XCTAssertTrue(outcome.projects.isEmpty)
        XCTAssertFalse(outcome.looksBroken)
        XCTAssertNil(outcome.diagnostic)
    }

    // MARK: - 追加写入

    /// 追加前必须把 `projects: []` 规范化，否则写出去的文件下次还是解析不出来 ——
    /// 这正是那份坏文件的产生方式。
    func testAppendNormalizesEmptyMarkerFirst() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("projects-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }

        try """
        # 注释要保住
        scan_dirs:
        - ~/code

        projects: []
        """.write(to: url, atomically: true, encoding: .utf8)

        ProjectStore.append(paths: ["/tmp/alpha", "/tmp/beta"], to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# 注释要保住"), "追加不该丢掉用户手写的注释")
        XCTAssertFalse(text.contains("projects: []"))

        let projects = ProjectYAML.parse(text)
        XCTAssertEqual(projects.map(\.name), ["alpha", "beta"])
    }

    /// 已经是正常格式时，追加不该动 `projects:` 那一行，也不该丢掉已有条目。
    func testAppendPreservesExistingEntries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("projects-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }

        try """
        projects:
          - name: existing
            aliases: [old]
            path: /tmp/existing
        """.write(to: url, atomically: true, encoding: .utf8)

        ProjectStore.append(paths: ["/tmp/fresh"], to: url)

        let projects = ProjectYAML.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(projects.map(\.name), ["existing", "fresh"])
        XCTAssertEqual(projects[0].aliases, ["old"], "已有条目的别名要原样保留")
    }

    func testNormalizeLeavesGoodFilesUntouched() {
        let good = "projects:\n  - name: a\n    path: /tmp/a\n"
        XCTAssertEqual(ProjectStore.normalizeProjectsKey(in: good), good)
    }

    // MARK: - 数据源选择

    /// 坏掉的候选**不能**把好的那份挡住。
    ///
    /// 原实现只判"文件存不存在"，于是 Application Support 里那份坏文件
    /// 永远排在前面，仓库里 21 个项目的好文件根本没机会被读到。
    @MainActor
    func testBrokenCandidateDoesNotShadowGoodOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let good = dir.appendingPathComponent("good.yaml")
        try "projects:\n  - name: good\n    path: /tmp/good\n"
            .write(to: good, atomically: true, encoding: .utf8)

        let store = ProjectStore(yamlURL: good)
        store.load()
        XCTAssertEqual(store.projects.map(\.name), ["good"])
        XCTAssertEqual(store.sourceURL, good)
        XCTAssertNil(store.loadDiagnostic)
    }

    /// 读到坏文件时，`sourceURL` 和诊断都要有值 —— UI 靠它们告诉用户去哪看。
    @MainActor
    func testBrokenSourceIsReported() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "notprojects:\n  - name: x\n    path: /tmp/x\n"
            .write(to: url, atomically: true, encoding: .utf8)

        let store = ProjectStore(yamlURL: url)
        store.load()
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertEqual(store.sourceURL, url)
        XCTAssertNotNil(store.loadDiagnostic)
    }
}
