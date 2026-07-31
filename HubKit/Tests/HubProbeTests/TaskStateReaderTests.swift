import XCTest
@testable import HubProbe

final class TaskStateReaderTests: XCTestCase {

    private var tasksDir: URL!

    override func setUpWithError() throws {
        tasksDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hubkit-tasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tasksDir)
    }

    private func makeSession(_ dirName: String) throws -> URL {
        let dir = tasksDir.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTask(
        in dir: URL, id: String, subject: String, status: String
    ) throws {
        let object: [String: Any] = [
            "id": id, "subject": subject, "description": "",
            "activeForm": "", "status": status, "blocks": [], "blockedBy": [],
        ]
        try JSONSerialization.data(withJSONObject: object)
            .write(to: dir.appendingPathComponent("\(id).json"))
    }

    private var reader: TaskStateReader { TaskStateReader(tasksDirectory: tasksDir) }

    // MARK: - 两种目录命名

    /// 当前形态：`session-<sessionId 前 8 位>`。
    /// 用的是本机真实会话的数据，与 Claude 界面上的
    /// `4 tasks (2 done, 1 in progress, 1 open)` 对得上。
    func testReadsShortPrefixDirectory() throws {
        let dir = try makeSession("session-4e14abb9")
        try writeTask(in: dir, id: "7", subject: "阶段一：修 nginx 现状", status: "completed")
        try writeTask(in: dir, id: "8", subject: "阶段二：allowlist 校验", status: "completed")
        try writeTask(in: dir, id: "9", subject: "阶段三：admin 网关面板", status: "pending")
        try writeTask(in: dir, id: "10", subject: "阶段四：证书告警 watcher", status: "in_progress")

        let snapshot = try XCTUnwrap(
            reader.read(sessionId: "4e14abb9-d998-4e60-9e2a-008c19247752")
        )
        XCTAssertEqual(snapshot.completed, 2)
        XCTAssertEqual(snapshot.inProgress, 1)
        XCTAssertEqual(snapshot.pending, 1)
        XCTAssertEqual(snapshot.unfinished, 2)
    }

    /// 旧形态：完整 UUID 做目录名。本机仍有残留，必须继续认。
    func testReadsFullUUIDDirectory() throws {
        let id = "8463e2ac-834c-4de2-be90-b6612189bcdd"
        let dir = try makeSession(id)
        try writeTask(in: dir, id: "1", subject: "老任务", status: "pending")

        let snapshot = try XCTUnwrap(reader.read(sessionId: id))
        XCTAssertEqual(snapshot.pending, 1)
        XCTAssertEqual(snapshot.nextSubject, "老任务")
    }

    // MARK: - nextSubject 的取法

    /// 正在做的优先于还没开始的 —— 提醒里该说"正在做什么"，不是"还欠什么"。
    func testInProgressWinsOverPending() throws {
        let dir = try makeSession("session-aaaaaaaa")
        try writeTask(in: dir, id: "1", subject: "还没开始的", status: "pending")
        try writeTask(in: dir, id: "9", subject: "正在做的", status: "in_progress")

        let snapshot = try XCTUnwrap(reader.read(sessionId: "aaaaaaaa-0000-0000-0000-000000000000"))
        XCTAssertEqual(snapshot.nextSubject, "正在做的")
    }

    /// 文件名是 `7.json` / `10.json`，必须按**数值**排。
    /// 按字符串排的话 "10" 会排到 "7" 前面，提醒就会指向错误的任务。
    func testPendingOrderIsNumericNotLexicographic() throws {
        let dir = try makeSession("session-bbbbbbbb")
        try writeTask(in: dir, id: "10", subject: "第十项", status: "pending")
        try writeTask(in: dir, id: "7", subject: "第七项", status: "pending")

        let snapshot = try XCTUnwrap(reader.read(sessionId: "bbbbbbbb-0000-0000-0000-000000000000"))
        XCTAssertEqual(snapshot.nextSubject, "第七项")
    }

    // MARK: - 容错

    /// 任务清单是边跑边写的，撞上半截 json 完全正常。
    /// **单个文件坏掉不能让整个目录失效。**
    func testCorruptFileDoesNotKillTheDirectory() throws {
        let dir = try makeSession("session-cccccccc")
        try writeTask(in: dir, id: "1", subject: "好的任务", status: "pending")
        try Data("{\"id\":\"2\",\"subject\":\"半截".utf8)
            .write(to: dir.appendingPathComponent("2.json"))

        let snapshot = try XCTUnwrap(reader.read(sessionId: "cccccccc-0000-0000-0000-000000000000"))
        XCTAssertEqual(snapshot.pending, 1)
        XCTAssertEqual(snapshot.nextSubject, "好的任务")
    }

    /// `.lock` 和 `.highwatermark` 是目录里的常驻文件，不能被当成任务。
    func testDotFilesAreIgnored() throws {
        let dir = try makeSession("session-dddddddd")
        try Data("".utf8).write(to: dir.appendingPathComponent(".lock"))
        try Data("3".utf8).write(to: dir.appendingPathComponent(".highwatermark"))
        try writeTask(in: dir, id: "1", subject: "唯一的任务", status: "completed")

        let snapshot = try XCTUnwrap(reader.read(sessionId: "dddddddd-0000-0000-0000-000000000000"))
        XCTAssertEqual(snapshot.total, 1)
        XCTAssertEqual(snapshot.completed, 1)
    }

    /// 目录存在但没有任务 —— 本机 7 个会话里有 4 个是这样。
    /// 要返回空快照而不是 nil，两者语义不同：
    /// 空快照 = "确实没有待办"，nil = "这个会话没用任务工具"。
    func testEmptyDirectoryReturnsEmptySnapshot() throws {
        _ = try makeSession("session-eeeeeeee")
        let snapshot = try XCTUnwrap(reader.read(sessionId: "eeeeeeee-0000-0000-0000-000000000000"))
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertNil(snapshot.nextSubject)
    }

    func testMissingDirectoryReturnsNil() {
        XCTAssertNil(reader.read(sessionId: "ffffffff-0000-0000-0000-000000000000"))
    }
}
