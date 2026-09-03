import HubCore
import HubIPC
import XCTest
@testable import HubProjects
@testable import HubUI

/// 「验收守望」注入必须受盯梢开关管辖（issue：盯梢关了还注入）。
///
/// 实机事故：盯梢 toggle 是关的，Stop hook 仍把 3 条验收清单 + 「另有 114 条
/// 未列出」以 block 决策注入进一个 50 分钟的会话，Claude 被无关任务的核对
/// 要求带偏主线。根因：`interceptDecision` 和盯梢 toggle 是两套零耦合的系统，
/// 注入链路上**没有任何开关**。
///
/// 修法：`HookCoordinator.isInterventionEnabled` 闭包注入（默认 nil = 纯观察），
/// main.swift 接到 `watchdog.isWatching` —— 一个开关管住所有对会话的干预。
@MainActor
final class HookInterventionGateTests: XCTestCase {

    private let project = "/tmp/gate-project"

    private func makeCoordinator(acceptance: AcceptanceStore) -> HookCoordinator {
        HookCoordinator(
            store: SessionStore(),
            approvals: ApprovalCoordinator(logURL: nil),
            prompts: AgentPromptCoordinator(),
            notifications: HubNotificationCenter(connectToSystem: false),
            projects: ProjectStore(yamlURL: nil, pinURL: nil),
            acceptance: acceptance
        )
    }

    private func stopEvent(session: String = "s1") -> HookEvent {
        HookEvent(kind: .stop, requestId: UUID().uuidString, sessionId: session, cwd: project)
    }

    private func armedStoreWithPending() -> AcceptanceStore {
        let store = AcceptanceStore(directory: nil)
        store.add(AcceptanceItem(text: "还没做的要点", origin: .userPrompt), to: project)
        store.arm(sessionId: "s1")
        return store
    }

    /// **默认（没接开关）= 纯观察，绝不注入。**
    func testDefaultIsPureObservation() {
        let acceptance = armedStoreWithPending()
        let hooks = makeCoordinator(acceptance: acceptance)

        let decision = hooks.interceptDecision(for: stopEvent(), projectPath: project)

        XCTAssertEqual(decision.verdict, .allow)
    }

    /// 开关关着：不注入，但**膛必须照卸** —— 防死循环的结构不因开关而改变。
    func testGateOffStillDisarms() {
        let acceptance = armedStoreWithPending()
        let hooks = makeCoordinator(acceptance: acceptance)
        hooks.isInterventionEnabled = { _ in false }

        _ = hooks.interceptDecision(for: stopEvent(), projectPath: project)

        XCTAssertFalse(acceptance.isArmed(sessionId: "s1"), "开关关着也要卸膛")
    }

    /// 开关关着的那些收工**不许烧冷却时间戳** ——
    /// 否则用户一打开盯梢，前 15 分钟一次都拦不了，开关看起来是坏的。
    func testGateOffDoesNotBurnTheCooldown() {
        let acceptance = armedStoreWithPending()
        let hooks = makeCoordinator(acceptance: acceptance)

        hooks.isInterventionEnabled = { _ in false }
        _ = hooks.interceptDecision(for: stopEvent(), projectPath: project)

        // 用户打开盯梢，又说了一句话（重新上膛）。
        hooks.isInterventionEnabled = { _ in true }
        acceptance.arm(sessionId: "s1")
        let decision = hooks.interceptDecision(for: stopEvent(), projectPath: project)

        XCTAssertEqual(decision.verdict, .deny, "刚打开盯梢的第一次收工就该能拦")
    }

    /// 开关开着：恢复原注入行为，且被问的条目 askCount 记上一笔。
    func testGateOnInterceptsAndCountsTheAsk() {
        let acceptance = armedStoreWithPending()
        let hooks = makeCoordinator(acceptance: acceptance)
        hooks.isInterventionEnabled = { _ in true }

        let decision = hooks.interceptDecision(for: stopEvent(), projectPath: project)

        XCTAssertEqual(decision.verdict, .deny)
        XCTAssertEqual(decision.reason?.contains("验收守望"), true)
        XCTAssertEqual(
            acceptance.ledger(for: project).items.first?.askCount, 1,
            "真拦下来了才算「问过一次」"
        )
    }

    /// stopHookActive（Claude 已在续跑）永远优先于开关 —— 防重入不许被绕过。
    func testStopHookActiveStillWinsOverTheGate() {
        let acceptance = armedStoreWithPending()
        let hooks = makeCoordinator(acceptance: acceptance)
        hooks.isInterventionEnabled = { _ in true }

        let event = HookEvent(
            kind: .stop, requestId: "r", sessionId: "s1", cwd: project, stopHookActive: true
        )

        XCTAssertEqual(hooks.interceptDecision(for: event, projectPath: project).verdict, .allow)
    }
}
