import XCTest
@testable import HubIPC

/// Stop hook 的应答格式和超时阶梯。
///
/// Stop 从「非阻塞、输出被忽略」改成了「阻塞、输出决定 Claude 停不停」，
/// 这是全案侵入性最大的改动 —— 它挡在**每一次收工**前面。
final class StopHookOutputTests: XCTestCase {

    // MARK: - 输出格式

    /// 绝大多数情况都走这条：什么都不输出 = 正常收工。
    func testAllowPrintsNothing() {
        XCTAssertNil(HookDecision.allow.stopOutputJSON())
    }

    func testDenyBlocksWithTheReason() throws {
        let decision = HookDecision(verdict: .deny, reason: "还有 3 项没核对")

        let json = try XCTUnwrap(decision.stopOutputJSON())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["decision"] as? String, "block")
        XCTAssertEqual(object["reason"] as? String, "还有 3 项没核对")
    }

    /// 没有理由的拦截等于让 Claude 空转一轮 —— 它收不到任何指示，
    /// 只能再说一遍"做完了"，然后又被拦。宁可不拦。
    func testDenyWithoutAReasonDoesNotBlock() {
        XCTAssertNil(HookDecision(verdict: .deny, reason: nil).stopOutputJSON())
        XCTAssertNil(HookDecision(verdict: .deny, reason: "").stopOutputJSON())
    }

    /// `ask` 是 PreToolUse 的语义，Stop 这条链路上没有对应概念 —— 不该输出。
    func testAskPrintsNothingOnTheStopChannel() {
        XCTAssertNil(HookDecision(verdict: .ask, reason: "随便").stopOutputJSON())
    }

    /// Stop 和 PreToolUse 的输出格式**完全不同**，别想着合并成一个方法。
    ///
    /// PreToolUse 是 `hookSpecificOutput.permissionDecision`，
    /// Stop 是顶层的 `decision` / `reason`。用错格式的后果是静默失效：
    /// Claude 认不出来就当没有输出，也就是照常收工。
    func testTheTwoChannelsUseDifferentShapes() throws {
        let decision = HookDecision(verdict: .deny, reason: "拦一下")

        let stop = try XCTUnwrap(decision.stopOutputJSON())
        let pre = try XCTUnwrap(decision.hookOutputJSON())

        XCTAssertTrue(stop.contains("\"decision\""))
        XCTAssertFalse(stop.contains("hookSpecificOutput"))
        XCTAssertTrue(pre.contains("hookSpecificOutput"))
        XCTAssertFalse(pre.contains("\"decision\":\"block\""))
    }

    // MARK: - 客户端和服务端必须对「谁在等应答」有共识

    /// **阻塞类事件的集合只能有一个定义。**
    ///
    /// 这条来自一次真实事故：把 Stop 改成阻塞式时只动了 hubctl（让它等应答），
    /// 服务端 `HubSocketServer` 里那句 `guard kind == .preToolUse` 原封不动 ——
    /// 于是 hubctl 等到的永远是连接关闭。
    ///
    /// 最难受的是它的**症状**：不报错、不超时、hook 10ms 就返回，
    /// 表现得和"清单里没有待办所以不用拦"一模一样。端到端测了三轮才找到。
    ///
    /// 现在两边都读 `Kind.expectsDecision`，分歧在结构上不成立。
    /// 这条测试钉住的是这个集合本身。
    func testOnlyBlockingKindsExpectADecision() {
        XCTAssertTrue(HookEvent.Kind.preToolUse.expectsDecision)
        XCTAssertTrue(HookEvent.Kind.stop.expectsDecision, "Stop 是阻塞的，服务端必须回写")

        for kind in [HookEvent.Kind.notification, .sessionEnd, .userPromptSubmit,
                     .sessionStart, .postToolUse, .subagentStop, .preCompact] {
            XCTAssertFalse(
                kind.expectsDecision,
                "\(kind.rawValue) 不该等应答 —— 等了会让 hubctl 白白挂在 socket 上"
            )
        }
    }

    // MARK: - 超时阶梯

    /// **内层必须先到期。**
    ///
    /// 这条守的是一次真实事故的镜像：审批那边曾经把服务端和客户端的超时设成
    /// 一样大，结果 hubctl 先判"没收到应答"按 fail-open 放行了一条
    /// `git push --force`，而服务端其实已经决定拒绝。
    ///
    /// Stop 这条链路方向相反（超时 = 不拦），但阶梯必须同样严格 ——
    /// 顺序错了会出现"服务端说要拦、客户端已经超时放过"的窗口，
    /// 表现为拦截时灵时不灵，极难排查。
    func testTheStopLadderIsStrictlyIncreasing() {
        XCTAssertLessThan(HookTimeouts.stopBridge, HookTimeouts.stopRead)
        XCTAssertLessThan(HookTimeouts.stopRead, TimeInterval(HookTimeouts.stopHookProcess))
    }

    /// Stop 的阶梯必须**远短于**审批阶梯。
    ///
    /// 它挡在每一次收工前面。挂到审批那条 75 秒的阶梯上，Hub 一卡住
    /// 用户每说一句话就要干等 75 秒 —— 那比这个功能本身值钱得多。
    func testTheStopLadderIsMuchShorterThanTheApprovalLadder() {
        XCTAssertLessThan(HookTimeouts.stopRead, HookTimeouts.clientRead / 5)
        XCTAssertLessThanOrEqual(HookTimeouts.stopHookProcess, 15)
    }
}
