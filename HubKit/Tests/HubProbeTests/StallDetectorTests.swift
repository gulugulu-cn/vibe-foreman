import XCTest
@testable import HubCore
@testable import HubProbe

final class StallDetectorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let detector = StallDetector()

    private func session(
        status: SessionStatus,
        silentFor: TimeInterval,
        waitingFor: String? = nil
    ) -> AgentSession {
        AgentSession(
            sessionId: "s1", pid: 4242, cwd: "/tmp/proj", name: "demo",
            status: status, rawStatus: status.rawValue, kind: .interactive,
            waitingFor: waitingFor,
            statusUpdatedAt: now.addingTimeInterval(-silentFor),
            updatedAt: now.addingTimeInterval(-silentFor)
        )
    }

    private func tail(
        text: String? = "干完了。", apiError: Bool = false
    ) -> TranscriptTail {
        TranscriptTail(
            lastAssistantText: text, endedWithApiError: apiError,
            lastUserMessageAt: nil, lastActivityAt: nil
        )
    }

    // MARK: - 干活中的会话永远不算卡住

    func testBusyAndShellNeverStall() {
        for status in [SessionStatus.busy, .shell] {
            let input = StallDetector.Input(
                session: session(status: status, silentFor: 3600), tail: tail()
            )
            XCTAssertNil(detector.evaluate(input, now: now), "\(status) 不该被判为卡住")
        }
    }

    // MARK: - ① 断线

    /// 断线**立即**报，不等阈值。异常没有"正常等待"一说。
    func testInterruptedFiresImmediately() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 1),
            tail: tail(text: "API Error: Connection closed mid-response.", apiError: true)
        )
        let finding = detector.evaluate(input, now: now)
        guard case .interrupted = finding?.reason else {
            return XCTFail("应判为断线，实际 \(String(describing: finding?.reason))")
        }
        XCTAssertEqual(finding?.grade, .high)
    }

    /// 断线优先级最高，即便同时还有未完成任务、还在提问。
    func testInterruptedOutranksEverythingElse() {
        let input = StallDetector.Input(
            session: session(status: .waiting, silentFor: 3600, waitingFor: "input needed"),
            tail: tail(text: "还要继续吗？", apiError: true),
            tasks: TaskSnapshot(pending: 3, inProgress: 1, completed: 0, nextSubject: "阶段三")
        )
        guard case .interrupted = detector.evaluate(input, now: now)?.reason else {
            return XCTFail("断线必须压过其它所有原因")
        }
    }

    // MARK: - ② 提问

    /// 真实样本：截图里 storefront-a 会话的最后一句。
    func testQuestionAtLastLineIsDetectedWithoutAI() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 300),
            tail: tail(text: """
            建议不要直接发布那个预览主题。
            需要我帮你把这两个提交精准推送到 live 吗？
            """)
        )
        guard case .askedQuestion(let q) = detector.evaluate(input, now: now)?.reason else {
            return XCTFail("最后一行是问句，应判为提问")
        }
        XCTAssertEqual(q, "需要我帮你把这两个提交精准推送到 live 吗？")
    }

    /// 正文中间的反问句**不能**误判 —— 这是纯启发式最容易翻车的地方，
    /// 所以只看最后一个非空行。真实样本：截图里 acme-admin 那条收尾回复。
    func testRhetoricalQuestionMidTextIsNotAQuestion() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 300),
            tail: tail(text: """
            颜色 vs 颜色值混乱？按你确认的方案已经处理。
            测试数据已清理，前后端服务都已重启在跑。
            """),
            busyDuration: 30 * 60
        )
        guard case .finishedAwaitingReview = detector.evaluate(input, now: now)?.reason else {
            return XCTFail("中间的问号不该让它变成提问")
        }
    }

    /// AI 说了算：AI 说不是提问，就算最后一行有问号也不算。
    func testAIOverridesTheHeuristic() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 300),
            tail: tail(text: "这样对吗？"),
            busyDuration: 30 * 60,
            ai: StallSummary(summary: "已完成重构", isQuestion: false)
        )
        guard case .finishedAwaitingReview = detector.evaluate(input, now: now)?.reason else {
            return XCTFail("AI 判定为非提问时应以 AI 为准")
        }
    }

    func testAICanPromoteToQuestionWithoutTrailingMark() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 300),
            tail: tail(text: "告诉我你想要哪一种"),
            ai: StallSummary(isQuestion: true, question: "你想要哪一种？")
        )
        guard case .askedQuestion(let q) = detector.evaluate(input, now: now)?.reason else {
            return XCTFail("AI 判定为提问时应升级")
        }
        XCTAssertEqual(q, "你想要哪一种？")
    }

    func testQuestionRespectsThreshold() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 30),   // < 90 秒
            tail: tail(text: "要继续吗？")
        )
        XCTAssertNil(detector.evaluate(input, now: now), "没到阈值不该报")
    }

    // MARK: - ③ 等授权

    func testWaitingStatusBecomesAwaitingDecision() {
        let input = StallDetector.Input(
            session: session(status: .waiting, silentFor: 120, waitingFor: "input needed"),
            tail: tail(text: "计划写好了。")
        )
        guard case .awaitingDecision(let why) = detector.evaluate(input, now: now)?.reason else {
            return XCTFail("waiting 状态应判为等授权")
        }
        XCTAssertEqual(why, "input needed")
    }

    // MARK: - ④ 未完成任务

    func testUnfinishedTasksCarryTheNextSubject() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 10 * 60),
            tail: tail(),
            tasks: TaskSnapshot(
                pending: 1, inProgress: 1, completed: 2, nextSubject: "阶段四：证书告警"
            )
        )
        guard case .unfinishedTasks(let pending, let running, let next) =
                detector.evaluate(input, now: now)?.reason
        else { return XCTFail("应判为有未完成任务") }
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(running, 1)
        XCTAssertEqual(next, "阶段四：证书告警")
    }

    /// 清单全做完了就不该按"有后续"报，要落到"待验收"。
    func testAllTasksDoneFallsThroughToReview() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 10 * 60),
            tail: tail(),
            tasks: TaskSnapshot(pending: 0, inProgress: 0, completed: 4),
            busyDuration: 30 * 60
        )
        guard case .finishedAwaitingReview = detector.evaluate(input, now: now)?.reason else {
            return XCTFail("任务全完成时应落到待验收")
        }
    }

    // MARK: - ⑤ 待验收与分级

    /// 用户明确要求"安静干完了也要提醒验收"，所以这是兜底结论而不是可选项。
    func testQuietlyFinishedStillReminds() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 5 * 60),
            tail: tail(text: "四项优化全部完成、实测通过并提交。"),
            busyDuration: 29 * 60
        )
        let finding = detector.evaluate(input, now: now)
        guard case .finishedAwaitingReview(let summary, let worked) = finding?.reason else {
            return XCTFail("应判为待验收")
        }
        XCTAssertEqual(summary, "四项优化全部完成、实测通过并提交。")
        XCTAssertEqual(worked, 29 * 60)
        XCTAssertEqual(finding?.grade, .high, "干了 29 分钟的活值得打断")
    }

    /// 干了半分钟的小活降级 —— 七八个会话都这么弹会立刻变成骚扰。
    func testShortWorkIsDowngraded() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 5 * 60),
            tail: tail(),
            busyDuration: 30
        )
        XCTAssertEqual(detector.evaluate(input, now: now)?.grade, .low)
    }

    /// 不知道干了多久时按高优 —— 漏提醒比多提醒一次代价大。
    func testUnknownWorkDurationGradesHigh() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 5 * 60),
            tail: tail(),
            busyDuration: nil
        )
        XCTAssertEqual(detector.evaluate(input, now: now)?.grade, .high)
    }

    func testReviewRespectsThreshold() {
        let input = StallDetector.Input(
            session: session(status: .idle, silentFor: 60),   // < 3 分钟
            tail: tail()
        )
        XCTAssertNil(detector.evaluate(input, now: now))
    }

    // MARK: - 优先级整体

    func testPriorityOrderIsStable() {
        let ordered: [StallReason] = [
            .interrupted("x"),
            .askedQuestion("x"),
            .awaitingDecision(nil),
            .unfinishedTasks(pending: 1, inProgress: 0, next: nil),
            .finishedAwaitingReview(summary: nil, workedFor: 0),
        ]
        XCTAssertEqual(ordered.map(\.priority), [0, 1, 2, 3, 4])
        XCTAssertEqual(Set(ordered.map(\.symbol)).count, 5, "每类的图标要能区分")
    }
}
