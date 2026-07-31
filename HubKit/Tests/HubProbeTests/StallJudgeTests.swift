import XCTest
@testable import HubProbe

final class StallJudgeTests: XCTestCase {

    // MARK: - 解析

    /// **实测的真实回复**：即使提示词明说"只输出 JSON 对象"，模型照样包围栏。
    /// 不剥围栏的话解析必然失败，AI 这一层等于完全没生效。
    func testStripsCodeFenceThatModelAddsAnyway() throws {
        let raw = """
        ```json
        {"summary":"四项优化完成测试，问是否推送到live","isQuestion":true,\
        "question":"需要帮你把这两个提交精准推送到 live 吗？",\
        "options":["需要推送","等待确认","暂时不推"],"nextAction":"确认推送目标分支"}
        ```
        """
        let summary = try XCTUnwrap(StallJudge.parse(raw))
        XCTAssertEqual(summary.summary, "四项优化完成测试，问是否推送到live")
        XCTAssertTrue(summary.isQuestion)
        XCTAssertEqual(summary.question, "需要帮你把这两个提交精准推送到 live 吗？")
        XCTAssertEqual(summary.options, ["需要推送", "等待确认", "暂时不推"])
        XCTAssertEqual(summary.nextAction, "确认推送目标分支")
    }

    func testParsesBareJSON() throws {
        let summary = try XCTUnwrap(
            StallJudge.parse(#"{"summary":"重构完成","isQuestion":false}"#)
        )
        XCTAssertEqual(summary.summary, "重构完成")
        XCTAssertFalse(summary.isQuestion)
        XCTAssertTrue(summary.options.isEmpty)
    }

    /// 不是提问时不该带选项 —— 否则岛上会冒出一排无意义的按钮。
    func testOptionsAreDroppedWhenNotAQuestion() throws {
        let summary = try XCTUnwrap(StallJudge.parse(
            #"{"summary":"完成","isQuestion":false,"options":["是","否"]}"#
        ))
        XCTAssertTrue(summary.options.isEmpty)
    }

    func testOptionsAreCappedAndTrimmed() throws {
        let summary = try XCTUnwrap(StallJudge.parse(
            #"{"isQuestion":true,"options":[" 一 ","二","三","四","五",""]}"#
        ))
        XCTAssertEqual(summary.options, ["一", "二", "三", "四"])
    }

    /// 空字符串要变成 nil，不能让岛上显示一行空白。
    func testEmptyStringsBecomeNil() throws {
        let summary = try XCTUnwrap(StallJudge.parse(
            #"{"summary":"  ","isQuestion":true,"question":"","nextAction":""}"#
        ))
        XCTAssertNil(summary.summary)
        XCTAssertNil(summary.question)
        XCTAssertNil(summary.nextAction)
    }

    /// 模型胡说八道时必须干净地失败 —— 上层会退回"完成了一轮，去看看"，
    /// 提醒照发。这是这一层刻意设计的低代价失败模式。
    func testGarbageReturnsNil() {
        XCTAssertNil(StallJudge.parse("我觉得这个会话应该继续"))
        XCTAssertNil(StallJudge.parse("```json\n{半截\n```"))
        XCTAssertNil(StallJudge.parse(""))
        XCTAssertNil(StallJudge.parse("[1,2,3]"))
    }

    // MARK: - 冷却

    func testCooldownSuppressesRepeatJudgement() async {
        let judge = StallJudge(
            configuration: .init(cooldown: 600),
            // 给一个存在且可执行的路径，避免因为找不到 claude 而提前 return。
            executable: "/bin/echo"
        )
        let t0 = Date()
        var allowed = await judge.shouldJudge(sessionId: "s1", now: t0)
        XCTAssertTrue(allowed)

        _ = await judge.judge(sessionId: "s1", assistantText: "x", now: t0)

        allowed = await judge.shouldJudge(sessionId: "s1", now: t0.addingTimeInterval(300))
        XCTAssertFalse(allowed, "冷却期内不该重复判")

        allowed = await judge.shouldJudge(sessionId: "s1", now: t0.addingTimeInterval(601))
        XCTAssertTrue(allowed, "过了冷却应该能再判")
    }

    /// 会话重新开工后要能立刻重判，不该被上一轮的冷却挡住。
    func testForgetClearsCooldown() async {
        let judge = StallJudge(configuration: .init(cooldown: 600), executable: "/bin/echo")
        let t0 = Date()
        _ = await judge.judge(sessionId: "s1", assistantText: "x", now: t0)

        let blocked = await judge.shouldJudge(sessionId: "s1", now: t0)
        XCTAssertFalse(blocked)

        await judge.forget(sessionId: "s1")
        let allowed = await judge.shouldJudge(sessionId: "s1", now: t0)
        XCTAssertTrue(allowed)
    }

    func testDisabledJudgeNeverRuns() async {
        let judge = StallJudge(configuration: .init(enabled: false), executable: "/bin/echo")
        let allowed = await judge.shouldJudge(sessionId: "s1")
        XCTAssertFalse(allowed)
        let summary = await judge.judge(sessionId: "s1", assistantText: "x")
        XCTAssertNil(summary)
    }

    /// 找不到 claude 时安静地不干活，不能让整个提醒链路失败。
    func testMissingExecutableDisablesJudging() async {
        let judge = StallJudge(executable: "/nonexistent/claude")
        let summary = await judge.judge(sessionId: "s1", assistantText: "x")
        XCTAssertNil(summary)
    }

    // MARK: - 账本

    /// 额度消耗必须可见 —— 用户看不到消耗就不会信任一个背着他调 AI 的功能。
    func testLedgerCountsFailures() async {
        // /bin/echo 会成功退出但输出的不是我们要的 JSON 信封 → 记为失败。
        let judge = StallJudge(executable: "/bin/echo")
        _ = await judge.judge(sessionId: "s1", assistantText: "x")
        let ledger = await judge.ledger
        XCTAssertEqual(ledger.calls, 1)
        XCTAssertEqual(ledger.failures, 1)
    }
}
