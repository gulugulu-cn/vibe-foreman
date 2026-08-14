import XCTest
@testable import HubProjects

/// 从 projects.yaml 里删掉项目。
///
/// 实机背景：40 条里有 6 条指向已经被删掉的目录（agentx-agent 那一批）。
/// 它们不是无害的脏数据 —— tmux 对不存在的 `-c` 目录**返回 0 并静默回落到
/// 家目录**，`open` 则什么都不做，于是点这些项目表现成
/// 「Finder 没反应」+「Claude 开到 /Users/dev」，看起来像右键菜单坏了。
/// 用户当时的话是"有目录污染的，不能清理"。
///
/// 删除必须是**文本手术**：这份文件是给人手改的，解析完重写会把注释、
/// 别名、描述、分段空行全抹平。`AcceptanceStore` 和 `SessionWatchdog`
/// 都因为"内存状态直接盖盘"弄丢过手改内容，同一个错不能犯第三次。
final class ProjectRemovalTests: XCTestCase {

    private let sample = """
    # 我的项目清单
    scan_dirs:
      - ~/Documents/code

    projects:
      - name: keep-me
        path: ~/code/keep-me
        aliases: [k, 保留]
        description: "要留下的"

      # 这条是坏的，目录早没了
      - name: dead
        path: ~/code/dead
        aliases: [d]
        description: "该删掉"

      - name: also-keep
        path: ~/code/also-keep
    """

    private func parse(_ text: String) -> [String] {
        ProjectYAML.parse(text).map(\.name)
    }

    // MARK: - 删对了吗

    func testRemovesTheTargetedEntry() {
        let result = ProjectYAML.removing(names: ["dead"], from: sample)
        XCTAssertEqual(parse(result), ["keep-me", "also-keep"])
    }

    /// **不能留下没主的字段行。**
    ///
    /// 只删 `- name: dead` 那一行的话，下面的 `path:` / `aliases:` 会被解析器
    /// 挂到**前一条**项目上 —— 删一条把另一条也弄坏了，而且完全静默。
    func testDoesNotLeaveOrphanFieldsBehind() {
        let result = ProjectYAML.removing(names: ["dead"], from: sample)
        XCTAssertFalse(result.contains("~/code/dead"), "path 行没被一起删掉：\n\(result)")
        XCTAssertFalse(result.contains("该删掉"), "description 行没被一起删掉")

        let kept = ProjectYAML.parse(result)
        XCTAssertEqual(kept.first?.path, "~/code/keep-me", "前一条的 path 被污染了")
        XCTAssertEqual(kept.first?.aliases, ["k", "保留"], "前一条的别名被污染了")
    }

    /// 手写的注释、别名、描述一个都不能丢 —— 这是不用"重写整份"的全部理由。
    func testPreservesHandWrittenContent() {
        let result = ProjectYAML.removing(names: ["dead"], from: sample)
        XCTAssertTrue(result.contains("# 我的项目清单"))
        XCTAssertTrue(result.contains("scan_dirs:"))
        XCTAssertTrue(result.contains("aliases: [k, 保留]"))
        XCTAssertTrue(result.contains("要留下的"))
    }

    /// 一次删多条（"清掉全部失效项目"走的就是这条）。
    func testRemovesSeveralAtOnce() {
        let result = ProjectYAML.removing(names: ["dead", "also-keep"], from: sample)
        XCTAssertEqual(parse(result), ["keep-me"])
    }

    /// 删最后一条时不能把后面的顶层段落一起吞掉。
    func testStopsAtTheNextTopLevelKey() {
        let text = """
        projects:
          - name: dead
            path: ~/code/dead

        scan_dirs:
          - ~/Documents/code
        """
        let result = ProjectYAML.removing(names: ["dead"], from: text)
        XCTAssertTrue(result.contains("scan_dirs:"), "顶层段落被一起删了：\n\(result)")
        XCTAssertTrue(result.contains("~/Documents/code"))
    }

    /// 名字对不上就一个字都不该动。
    func testUnknownNameChangesNothing() {
        XCTAssertEqual(ProjectYAML.removing(names: ["nope"], from: sample), sample)
    }

    func testEmptySetChangesNothing() {
        XCTAssertEqual(ProjectYAML.removing(names: [], from: sample), sample)
    }

    // MARK: - 加回来

    /// 扫描只认有 `.git` 的目录，所以 monorepo 子目录、没 git init 的目录
    /// 永远扫不进来 —— 实机 40 条里有 7 条是这种，只能手写 yaml。
    /// `addExisting` 是那个缺掉的入口。
    @MainActor
    func testAddExistingRegistersAnyDirectory() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let dir = url.deletingLastPathComponent()
            .appendingPathComponent("plain-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertTrue(store.addExisting(path: dir.path))
        XCTAssertTrue(store.projects.contains { $0.name == "plain-dir" })
    }

    /// 目录不存在就不该登记 —— 登记进去就是又造一条"点了开到家目录"的污染。
    @MainActor
    func testAddExistingRejectsMissingDirectory() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertFalse(store.addExisting(path: "/definitely/not/here"))
    }

    /// 加过的不再加第二遍：重名条目会让删除变得没法预测。
    @MainActor
    func testAddExistingIsIdempotent() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let dir = url.deletingLastPathComponent()
            .appendingPathComponent("twice", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertTrue(store.addExisting(path: dir.path))
        XCTAssertFalse(store.addExisting(path: dir.path))
        XCTAssertEqual(store.projects.count { $0.name == "twice" }, 1)
    }

    /// 目录没了的项目要被标出来。不标的话用户看到的是一个完全正常的行，
    /// 点下去却开到家目录 —— 那正是这次事故的样子。
    @MainActor
    func testMissingDirectoriesAreFlagged() throws {
        let (store, url) = try makeStore(
            yaml: """
            projects:
              - name: gone
                path: /definitely/not/here
            """
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let gone = try XCTUnwrap(store.projects.first)
        XCTAssertTrue(store.isMissing(gone))
        XCTAssertEqual(store.missingProjects.map(\.name), ["gone"])
    }

    @MainActor
    private func makeStore(yaml: String? = nil) throws -> (ProjectStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("projstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("projects.yaml")
        try (yaml ?? "projects:\n").write(to: url, atomically: true, encoding: .utf8)

        let store = ProjectStore(yamlURL: url, pinURL: nil)
        store.load()
        return (store, url)
    }
}
