import HubIPC
import XCTest
@testable import HubUI

@MainActor
final class ApprovalCoordinatorTests: XCTestCase {

    // 每个 case 都用 `logURL: nil` 建协调器 —— 默认路径指向用户真实的
    // ~/Library/Application Support/claude-hub/approval-log.json，
    // 测试跑进去既会互相污染，也会往用户数据里写垃圾。

    private func request(
        id: String = "r1", risk: RiskLevel = .irreversible, clientPid: pid_t = 0
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: id, sessionId: "s1", projectName: "demo", cwd: "/tmp",
            toolName: "Bash", command: "git push --force origin main",
            risk: risk, clientPid: clientPid
        )
    }

    // MARK: - 决策必须原样送回

    /// 这条看着平凡，但它守的是整个系统里**唯一一个做错了会真删代码**的地方：
    /// 用户点了拒绝，hook 那一侧必须收到拒绝。中间任何一环把它降级成放行，
    /// 都会让"高风险操作审批"变成一个假的安全感。
    func testDenyReachesTheWaitingHook() async {
        let coordinator = ApprovalCoordinator(logURL: nil)
        let target = request()

        let decision = Task { await coordinator.requestDecision(for: target) }
        // 让 requestDecision 先把请求排进队列。
        while coordinator.current == nil {
            await Task.yield()
        }
        coordinator.deny(target)

        let result = await decision.value
        XCTAssertEqual(result.verdict, .deny)
        XCTAssertNil(coordinator.current, "决策完成后卡片必须消失")
    }

    func testAllowReachesTheWaitingHook() async {
        let coordinator = ApprovalCoordinator(logURL: nil)
        let target = request(risk: .dangerous)

        let decision = Task { await coordinator.requestDecision(for: target) }
        while coordinator.current == nil {
            await Task.yield()
        }
        coordinator.allow(target)

        let result = await decision.value
        XCTAssertEqual(result.verdict, .allow)
    }

    // MARK: - 僵尸卡

    /// 发起方进程死了以后，卡片必须自己消失。
    ///
    /// 排障时真实撞到过：hook 进程被杀（Ctrl-C、会话关闭、超时被 kill），
    /// 服务端仍然阻塞在等决策上，岛上挂着一张**已经没人接收结果**的卡。
    /// 它不只是碍眼 —— 队列是先进先出的，这张僵尸卡会一直挡住后面真正
    /// 需要用户处理的请求。
    func testOrphanedRequestIsDroppedWhenClientDies() async {
        let coordinator = ApprovalCoordinator(logURL: nil)
        // PID 1 (launchd) 一定活着但不属于我们 —— kill 返回 EPERM，应判定为"还活着"。
        let alive = request(id: "alive", clientPid: 1)
        // 一个几乎不可能存在的 PID。
        let dead = request(id: "dead", clientPid: 0x7FFF_FFFE)

        let aliveDecision = Task { await coordinator.requestDecision(for: alive) }
        let deadDecision = Task { await coordinator.requestDecision(for: dead) }
        while coordinator.queue.count < 2 {
            await Task.yield()
        }

        coordinator.startOrphanSweep()
        let outcome = await deadDecision.value
        coordinator.stopOrphanSweep()

        XCTAssertEqual(outcome.verdict, .deny, "发起方已死，必须按拒绝收尾")
        XCTAssertEqual(coordinator.queue.count, 1, "只该清掉死掉的那一条")
        XCTAssertEqual(coordinator.current?.id, "alive")

        coordinator.deny(alive)
        _ = await aliveDecision.value
    }

    /// `clientPid == 0` 表示"不知道发起方是谁"，绝不能当成已死。
    func testUnknownClientPidIsNeverTreatedAsOrphan() async {
        let coordinator = ApprovalCoordinator(logURL: nil)
        let target = request(clientPid: 0)

        let decision = Task { await coordinator.requestDecision(for: target) }
        while coordinator.current == nil {
            await Task.yield()
        }

        coordinator.startOrphanSweep()
        try? await Task.sleep(for: .seconds(3))
        XCTAssertNotNil(coordinator.current, "未知发起方的请求不该被清掉")
        coordinator.stopOrphanSweep()

        coordinator.deny(target)
        _ = await decision.value
    }

    // MARK: - 队列

    /// 跳过是"稍后再说"，不是"拒绝"——不能顺手把它 resolve 掉。
    func testSkipMovesToBackWithoutResolving() async {
        let coordinator = ApprovalCoordinator(logURL: nil)
        let first = request(id: "a")
        let second = request(id: "b")

        let firstDecision = Task { await coordinator.requestDecision(for: first) }
        let secondDecision = Task { await coordinator.requestDecision(for: second) }
        while coordinator.queue.count < 2 {
            await Task.yield()
        }

        coordinator.skip(first)
        XCTAssertEqual(coordinator.current?.id, "b")
        XCTAssertEqual(coordinator.queue.count, 2, "跳过不该让请求消失")

        coordinator.deny(second)
        coordinator.deny(first)
        let firstResult = await firstDecision.value
        let secondResult = await secondDecision.value
        XCTAssertEqual(firstResult.verdict, .deny)
        XCTAssertEqual(secondResult.verdict, .deny)
    }

    /// 队列只剩一条时跳过没有意义，且不能把它弄丢。
    func testSkipIsNoOpForTheOnlyRequest() async {
        let coordinator = ApprovalCoordinator(logURL: nil)
        let only = request()

        let decision = Task { await coordinator.requestDecision(for: only) }
        while coordinator.current == nil {
            await Task.yield()
        }

        coordinator.skip(only)
        XCTAssertEqual(coordinator.current?.id, only.id)

        coordinator.deny(only)
        _ = await decision.value
    }

    /// 每一次拦截都要留痕，包括被清掉的僵尸请求 —— 审批日志是用户
    /// 决定"要不要把 dangerous 一档也开启拦截"的唯一依据。
    func testEveryResolutionIsLogged() async {
        let coordinator = ApprovalCoordinator(logURL: nil)
        let target = request()

        let decision = Task { await coordinator.requestDecision(for: target) }
        while coordinator.current == nil {
            await Task.yield()
        }
        coordinator.deny(target)
        _ = await decision.value

        XCTAssertEqual(coordinator.log.count, 1)
        XCTAssertEqual(coordinator.log.first?.verdict, "deny")
        XCTAssertTrue(coordinator.log.first?.intercepted == true)
    }

    /// 日志必须活过重启。
    ///
    /// 这份数据的用途是"看一周再决定要不要把 dangerous 一档也拦上"——
    /// 只存内存的话每次重启都归零，那个决策永远做不了。
    func testLogSurvivesRestart() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = ApprovalCoordinator(logURL: url)
        let target = request()
        let decision = Task { await first.requestDecision(for: target) }
        while first.current == nil { await Task.yield() }
        first.deny(target)
        _ = await decision.value

        // 换一个实例，模拟 app 重启。
        let reopened = ApprovalCoordinator(logURL: url)
        XCTAssertEqual(reopened.log.count, 1)
        XCTAssertEqual(reopened.log.first?.command, target.command)
        XCTAssertEqual(reopened.log.first?.verdict, "deny")

        reopened.clearLog()
        XCTAssertTrue(ApprovalCoordinator(logURL: url).log.isEmpty)
    }
}
