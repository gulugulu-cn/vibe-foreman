import HubCore
import HubProbe
import XCTest
@testable import HubUI

/// 追踪「AI 自己答应要做的事」。
///
/// 这一档来自用户的一句观察：清单里全是他说过的话，**AI 自己列的 todo
/// 一条都没有**。而「它自己列了 6 项，做完 3 项就说完事了」恰恰是遗漏
/// 最直接的证据，且这类承诺不在用户原话里，别处根本抓不到。
@MainActor
final class AssistantTaskTests: XCTestCase {

    private let project = "/tmp/demo-project"
    private let session = "s1"

    private func task(_ text: String, done: Bool = false) -> AcceptanceItem {
        AcceptanceItem(
            text: text, origin: .assistantTask,
            status: done ? .confirmed : .open, sourceSessionId: session
        )
    }

    /// AI 的计划和用户的原话必须**看得出区别**。
    ///
    /// 混成一档就等于把待核对的自述当成了权威基线 ——
    /// 而那正是这个功能要防的事。
    func testAssistantTasksAreDistinguishableFromUserRequirements() {
        XCTAssertFalse(AcceptanceItem.Origin.assistantTask.isFromUser)
        XCTAssertFalse(AcceptanceItem.Origin.inferred.isFromUser)
        XCTAssertTrue(AcceptanceItem.Origin.userPrompt.isFromUser)
        XCTAssertTrue(AcceptanceItem.Origin.plan.isFromUser)
        XCTAssertTrue(AcceptanceItem.Origin.manual.isFromUser)
        XCTAssertEqual(AcceptanceItem.Origin.assistantTask.label, "AI 计划")
    }

    /// 上一轮没做完、这一轮 Claude 自己勾掉了的，要跟着变成已确认。
    ///
    /// 不同步的话它们会永远挂在「未验收」，用户得手动一条条清 ——
    /// 清不动的清单最后就没人看了。
    func testTasksClaudeFinishedAreSynced() {
        let store = AcceptanceStore(directory: nil)
        store.add(task("写数据层"), to: project)
        store.add(task("接 UI"), to: project)

        store.syncAssistantTasks(done: ["写数据层"], in: project)

        let items = store.ledger(for: project).items
        XCTAssertEqual(items.first { $0.text == "写数据层" }?.status, .confirmed)
        XCTAssertEqual(items.first { $0.text == "接 UI" }?.status, .open)
    }

    /// **同步不能碰用户终裁过的项。** 理由同 applyAudit：
    /// 用户划掉了「这条不做了」，Claude 那边勾了完成也不该把它翻回来。
    func testSyncDoesNotTouchUserVerdicts() {
        let store = AcceptanceStore(directory: nil)
        let item = task("这条我不要了")
        store.add(item, to: project)
        store.setStatus(.dropped, forID: item.id, in: project)

        store.syncAssistantTasks(done: ["这条我不要了"], in: project)

        XCTAssertEqual(store.ledger(for: project).items.first?.status, .dropped)
    }

    /// 同步只影响 `.assistantTask` 那一档。
    ///
    /// Claude 勾掉自己的 todo，不代表用户提的需求就做完了 ——
    /// 两者恰好同名时尤其危险（"发布新版本"）。
    func testSyncOnlyAffectsAssistantTasks() {
        let store = AcceptanceStore(directory: nil)
        store.add(AcceptanceItem(text: "发布新版本", origin: .userPrompt), to: project)

        store.syncAssistantTasks(done: ["发布新版本"], in: project)

        XCTAssertEqual(
            store.ledger(for: project).items.first?.status, .open,
            "Claude 勾掉自己的 todo，不等于用户提的需求做完了"
        )
    }

    /// 「还差几项」必须按**会话**算，不能按项目。
    ///
    /// 用户问的是「这一轮它答应的做全了没」，跨会话混在一起答不了这个问题。
    func testUnfinishedIsScopedToOneSession() {
        let store = AcceptanceStore(directory: nil)
        store.add(task("这一轮的"), to: project)
        store.add(
            AcceptanceItem(text: "上一轮的", origin: .assistantTask, sourceSessionId: "other"),
            to: project
        )

        let pending = store.unfinishedAssistantTasks(sessionId: session, in: project)

        XCTAssertEqual(pending.map(\.text), ["这一轮的"])
    }

    func testFinishedTasksAreNotReportedAsPending() {
        let store = AcceptanceStore(directory: nil)
        store.add(task("已经做完了", done: true), to: project)

        XCTAssertTrue(store.unfinishedAssistantTasks(sessionId: session, in: project).isEmpty)
    }
}

/// 逐条读 Claude 自己的 todo。
final class ClaudeTaskReadingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(session: String, files: [(String, String)]) throws {
        let dir = root.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }
    }

    func testReadsSubjectsAndStatus() throws {
        try write(session: "session-abcd1234", files: [
            ("1.json", #"{"id":"1","subject":"写数据层","status":"completed"}"#),
            ("2.json", #"{"id":"2","subject":"接 UI","status":"in_progress"}"#),
            ("3.json", #"{"id":"3","subject":"补测试","status":"pending"}"#),
        ])

        let tasks = TaskStateReader(tasksDirectory: root).readTasks(sessionId: "abcd1234efgh")

        XCTAssertEqual(tasks.map(\.subject), ["写数据层", "接 UI", "补测试"])
        XCTAssertEqual(tasks.map(\.done), [true, false, false])
    }

    /// **按文件名的数值排序**，不是字符串序 —— 否则 "10" 会排到 "7" 前面，
    /// 用户看到的任务顺序就和 Claude 界面上的对不上。
    func testOrdersNumericallyNotLexicographically() throws {
        try write(session: "session-abcd1234", files: [
            ("7.json", #"{"subject":"第七","status":"pending"}"#),
            ("10.json", #"{"subject":"第十","status":"pending"}"#),
        ])

        let tasks = TaskStateReader(tasksDirectory: root).readTasks(sessionId: "abcd1234")

        XCTAssertEqual(tasks.map(\.subject), ["第七", "第十"])
    }

    /// 单个文件坏掉不能让整个目录失效 —— 清单是边跑边写的，
    /// 撞上半截 JSON 完全正常。
    func testSkipsBrokenFiles() throws {
        try write(session: "session-abcd1234", files: [
            ("1.json", #"{"subject":"好的","status":"pending"}"#),
            ("2.json", #"{"subject":"半截"#),
            ("3.json", #"{"status":"pending"}"#),   // 没有 subject
        ])

        let tasks = TaskStateReader(tasksDirectory: root).readTasks(sessionId: "abcd1234")

        XCTAssertEqual(tasks.map(\.subject), ["好的"])
    }

    func testMissingSessionYieldsNothing() {
        XCTAssertTrue(TaskStateReader(tasksDirectory: root).readTasks(sessionId: "nope").isEmpty)
    }
}
