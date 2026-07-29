import XCTest
@testable import HubCore
@testable import HubProbe

final class ClaudeSessionReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hubkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(pid: Int, json: String) throws {
        try Data(json.utf8).write(to: tempDir.appendingPathComponent("\(pid).json"))
    }

    private func record(
        pid: Int, sessionId: String, status: String = "busy",
        cwd: String = "/tmp/p", updatedAt: Int? = nil
    ) -> String {
        var fields = [
            "\"pid\":\(pid)", "\"sessionId\":\"\(sessionId)\"",
            "\"cwd\":\"\(cwd)\"", "\"status\":\"\(status)\"", "\"kind\":\"interactive\"",
        ]
        if let updatedAt { fields.append("\"updatedAt\":\(updatedAt)") }
        return "{\(fields.joined(separator: ","))}"
    }

    /// 这是最关键的一条：实测 ~/.claude/sessions/ 里残留着好几天前已退出进程的
    /// json（死进程的文件不会被清理）。不过滤，岛上就会显示一堆幽灵会话。
    func testDeadProcessesAreFilteredOut() throws {
        try write(pid: 100, json: record(pid: 100, sessionId: "alive"))
        try write(pid: 200, json: record(pid: 200, sessionId: "dead"))

        let reader = ClaudeSessionReader(directory: tempDir)
        let sessions = reader.readAll(isAlive: { $0 == 100 })

        XCTAssertEqual(sessions.map(\.sessionId), ["alive"])
    }

    func testNonJsonFilesAreIgnored() throws {
        try write(pid: 100, json: record(pid: 100, sessionId: "s"))
        try Data("garbage".utf8).write(to: tempDir.appendingPathComponent("README.txt"))
        try Data("garbage".utf8).write(to: tempDir.appendingPathComponent("notes.md"))

        let sessions = ClaudeSessionReader(directory: tempDir).readAll(isAlive: { _ in true })
        XCTAssertEqual(sessions.count, 1)
    }

    /// 一个坏文件不能让整个探测失败 —— 那会让岛整片空白。
    func testCorruptFileDoesNotBreakOtherRecords() throws {
        try write(pid: 100, json: record(pid: 100, sessionId: "good"))
        try write(pid: 101, json: "{ this is not json")
        try write(pid: 102, json: record(pid: 102, sessionId: "also-good"))

        let sessions = ClaudeSessionReader(directory: tempDir).readAll(isAlive: { _ in true })
        XCTAssertEqual(Set(sessions.map(\.sessionId)), ["good", "also-good"])
    }

    /// resume 之后旧 PID 的 json 可能还在，而旧 PID 又恰好被系统复用给别的进程
    /// 从而通过判活。同一 sessionId 只能留一条，取 updatedAt 最新的。
    func testDuplicateSessionIdKeepsMostRecentlyUpdated() throws {
        try write(pid: 100, json: record(pid: 100, sessionId: "same", updatedAt: 1000))
        try write(pid: 200, json: record(pid: 200, sessionId: "same", updatedAt: 5000))

        let sessions = ClaudeSessionReader(directory: tempDir).readAll(isAlive: { _ in true })
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.pid, 200)
    }

    func testMissingDirectoryReturnsEmptyRatherThanCrashing() {
        let reader = ClaudeSessionReader(
            directory: tempDir.appendingPathComponent("does-not-exist")
        )
        XCTAssertTrue(reader.readAll(isAlive: { _ in true }).isEmpty)
    }

    func testAlivePIDsSetMatchesReadAll() throws {
        try write(pid: 100, json: record(pid: 100, sessionId: "a"))
        try write(pid: 200, json: record(pid: 200, sessionId: "b"))
        try write(pid: 300, json: record(pid: 300, sessionId: "c"))

        let reader = ClaudeSessionReader(directory: tempDir)
        XCTAssertEqual(reader.alivePIDs(isAlive: { $0 != 200 }), [100, 300])
    }

    func testDefaultDirectoryPointsAtClaudeSessions() {
        XCTAssertTrue(
            ClaudeSessionReader().directory.path.hasSuffix("/.claude/sessions")
        )
    }
}

final class TmuxBindingTests: XCTestCase {

    private func pane(_ windowId: String, pid: pid_t, name: String = "w") -> TmuxPane {
        TmuxPane(
            sessionName: "hub", windowId: windowId, windowName: name,
            paneId: "%1", panePid: pid, currentPath: "/tmp", currentCommand: "2.1.220"
        )
    }

    /// claude 就是 pane 的根进程 —— 直接相等的简单情况。
    func testBindsWhenClaudeIsPaneRoot() {
        let tree = ProcessTree(parents: [29976: 25111, 25111: 1])
        let binding = TmuxProbe().bindPanes(
            to: [29976], tree: tree, panes: [pane("@20", pid: 29976)]
        )
        XCTAssertEqual(binding[29976]?.windowId, "@20")
    }

    /// pane 根进程是 shell，claude 是它的子进程。实测 8 个窗口里有 2 个是这样，
    /// 所以绝不能用 `panePid == sessionPid` 直接相等去绑。
    func testBindsWhenClaudeIsDescendantOfPaneRoot() {
        let tree = ProcessTree(parents: [29976: 8000, 8000: 25111, 25111: 1])
        let binding = TmuxProbe().bindPanes(
            to: [29976], tree: tree, panes: [pane("@21", pid: 8000)]
        )
        XCTAssertEqual(binding[29976]?.windowId, "@21")
    }

    /// 不在任何 tmux pane 里的会话（跑在原生终端 tab 里）不该被误绑。
    func testSessionOutsideTmuxIsNotBound() {
        let tree = ProcessTree(parents: [61126: 61125, 61125: 21558, 21558: 1])
        let binding = TmuxProbe().bindPanes(
            to: [61126], tree: tree, panes: [pane("@20", pid: 29976)]
        )
        XCTAssertTrue(binding.isEmpty)
    }

    func testEachSessionBindsToItsOwnPane() {
        let tree = ProcessTree(parents: [
            29976: 25111, 90252: 25111, 97138: 25111, 25111: 1,
        ])
        let binding = TmuxProbe().bindPanes(
            to: [29976, 90252, 97138],
            tree: tree,
            panes: [
                pane("@20", pid: 29976), pane("@23", pid: 90252), pane("@22", pid: 97138),
            ]
        )
        XCTAssertEqual(binding[29976]?.windowId, "@20")
        XCTAssertEqual(binding[90252]?.windowId, "@23")
        XCTAssertEqual(binding[97138]?.windowId, "@22")
    }
}
