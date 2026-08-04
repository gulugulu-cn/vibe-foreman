import HubIPC
import XCTest
@testable import HubUI

@MainActor
final class AgentPromptCoordinatorTests: XCTestCase {

    private func request(
        id: String = "p1",
        payload: AgentPromptPayload = .questions([
            AgentQuestion(question: "用哪种方案？", options: [
                .init(label: "方案 A"), .init(label: "方案 B"),
            ]),
        ]),
        clientPid: pid_t = 0
    ) -> AgentPromptRequest {
        AgentPromptRequest(
            id: id, sessionId: "s1", projectName: "demo", cwd: "/tmp",
            payload: payload, clientPid: clientPid
        )
    }

    // MARK: - 作答动作 → 决策

    /// 点选选项走 deny + reason：这是把答案送回模型的唯一通道，
    /// reason 里必须带上选项原文。
    func testChooseSendsDenyWithOptionLabel() async {
        let coordinator = AgentPromptCoordinator()
        let target = request()

        let decision = Task { await coordinator.requestDecision(for: target) }
        while coordinator.current == nil { await Task.yield() }
        coordinator.choose(target, option: .init(label: "方案 A"))

        let result = await decision.value
        XCTAssertEqual(result.verdict, .deny)
        XCTAssertTrue(result.reason?.contains("方案 A") == true)
        XCTAssertNil(coordinator.current, "作答后卡片必须消失")
    }

    /// 批准计划必须是**显式** allow —— 普通 allow 在 wire 上是"不输出"，
    /// 那等于把计划确认又丢回终端，批准就没生效。
    func testApprovePlanSendsExplicitAllow() async {
        let coordinator = AgentPromptCoordinator()
        let target = request(payload: .plan("# 计划"))

        let decision = Task { await coordinator.requestDecision(for: target) }
        while coordinator.current == nil { await Task.yield() }
        coordinator.approvePlan(target)

        let result = await decision.value
        XCTAssertEqual(result.verdict, .allow)
        XCTAssertEqual(result.explicitAllow, true)
        XCTAssertNotNil(result.hookOutputJSON(), "批准必须真的输出决策")
    }

    /// 多题/多选：所有题的答案要合成一条 reason 一并回传，每题带上题目标签。
    func testSubmitAnswersJoinsAllQuestions() async {
        let coordinator = AgentPromptCoordinator()
        let target = request()

        let decision = Task { await coordinator.requestDecision(for: target) }
        while coordinator.current == nil { await Task.yield() }
        coordinator.submitAnswers(target, answers: [
            AgentAnswer(key: "压测方式", labels: ["混合"]),
            AgentAnswer(key: "回收策略", labels: ["A", "B"]),
        ])

        let result = await decision.value
        XCTAssertEqual(result.verdict, .deny)
        XCTAssertTrue(result.reason?.contains("压测方式：混合") == true)
        XCTAssertTrue(result.reason?.contains("回收策略：A、B") == true)
    }

    /// 拒绝进入计划模式：deny + 明确说"按当前方式继续"。
    func testRejectEnterPlanSendsDeny() async {
        let coordinator = AgentPromptCoordinator()
        let target = request(payload: .enterPlan)

        let decision = Task { await coordinator.requestDecision(for: target) }
        while coordinator.current == nil { await Task.yield() }
        coordinator.rejectEnterPlan(target)

        let result = await decision.value
        XCTAssertEqual(result.verdict, .deny)
        XCTAssertTrue(result.reason?.contains("计划模式") == true)
    }

    func testRejectPlanSendsDeny() async {
        let coordinator = AgentPromptCoordinator()
        let target = request(payload: .plan("# 计划"))

        let decision = Task { await coordinator.requestDecision(for: target) }
        while coordinator.current == nil { await Task.yield() }
        coordinator.rejectPlan(target)

        let result = await decision.value
        XCTAssertEqual(result.verdict, .deny)
        XCTAssertNotNil(result.reason)
    }

    /// 「去终端回答」= 不输出决策，终端原生对话框接管。
    func testPassthroughSendsPlainAllow() async {
        let coordinator = AgentPromptCoordinator()
        let target = request()

        let decision = Task { await coordinator.requestDecision(for: target) }
        while coordinator.current == nil { await Task.yield() }
        coordinator.passthrough(target)

        let result = await decision.value
        XCTAssertEqual(result.verdict, .allow)
        XCTAssertNil(result.hookOutputJSON(), "passthrough 绝不能输出任何决策")
    }

    // MARK: - 权限卡（免等待入队）

    /// 权限卡没有阻塞的 hook 在等：入队要能显示、收卡要能出队，全程不能崩。
    func testEnqueuedPermissionCardCanBeDismissed() {
        let coordinator = AgentPromptCoordinator()
        let card = request(id: "perm", payload: .permission(message: "Do you want to create a.md?"))

        coordinator.enqueue(card)
        XCTAssertEqual(coordinator.current?.id, "perm")
        XCTAssertTrue(coordinator.hasPermissionCard(for: "s1"))

        coordinator.dismiss(card)
        XCTAssertNil(coordinator.current)
        XCTAssertFalse(coordinator.hasPermissionCard(for: "s1"))
    }

    /// 免等待卡也要有超时兜底 —— 用户不理它，55 秒后自己消失，终端框还在。
    func testEnqueuedCardTimesOutAndLeavesQueue() async {
        let coordinator = AgentPromptCoordinator(timeout: 0.1)
        coordinator.enqueue(request(id: "perm", payload: .permission(message: "?")))

        try? await Task.sleep(for: .seconds(1))
        XCTAssertNil(coordinator.current, "超时后权限卡必须自己消失")
    }

    // MARK: - 超时方向（本功能的安全核心）

    /// 超时必须落在 allow（fail-open）。这是审批那边「超时必须 deny」的镜像：
    /// 审批超时 deny 是安全刹车；交互卡超时 allow 只是把问题交还给终端的
    /// 原生对话框。方向写反的话，用户离开 55 秒就会把 Claude 的正常提问
    /// 变成一次莫名其妙的失败。
    func testTimeoutResolvesToAllowNotDeny() async {
        let coordinator = AgentPromptCoordinator(timeout: 0.1)
        let target = request()

        let result = await coordinator.requestDecision(for: target)

        XCTAssertEqual(result.verdict, .allow)
        XCTAssertNil(result.hookOutputJSON(), "超时输出必须为空，让终端原生框接管")
        XCTAssertNil(coordinator.current, "超时后卡片必须消失")
    }

    // MARK: - 僵尸卡

    /// 发起方（hubctl）死了以后卡片必须自己消失，结局同样是中性的 allow。
    func testOrphanedRequestIsDroppedWhenClientDies() async {
        let coordinator = AgentPromptCoordinator()
        // PID 1 一定活着但不属于我们（EPERM = 活着）；另一个几乎不可能存在。
        let alive = request(id: "alive", clientPid: 1)
        let dead = request(id: "dead", clientPid: 0x7FFF_FFFE)

        let aliveDecision = Task { await coordinator.requestDecision(for: alive) }
        let deadDecision = Task { await coordinator.requestDecision(for: dead) }
        while coordinator.queue.count < 2 { await Task.yield() }

        coordinator.startOrphanSweep()
        let outcome = await deadDecision.value
        coordinator.stopOrphanSweep()

        XCTAssertEqual(outcome.verdict, .allow)
        XCTAssertEqual(coordinator.queue.count, 1, "只该清掉死掉的那一条")
        XCTAssertEqual(coordinator.current?.id, "alive")

        coordinator.passthrough(alive)
        _ = await aliveDecision.value
    }
}
