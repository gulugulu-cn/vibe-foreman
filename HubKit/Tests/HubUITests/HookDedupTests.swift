import HubIPC
import XCTest
@testable import HubUI

/// hook 事件去重。
///
/// 这一整个类型的存在理由是一条**实测出来的**事实：Claude Code 的 hook 配置是
/// 叠加执行的，不是覆盖。全局 `~/.claude/settings.json` 和项目级
/// `.claude/settings.json` 里的同名 hook 会各跑一遍 —— 本机拿一次真实
/// `claude -p` 验证过（项目级和全局的 UserPromptSubmit / Stop 各触发了一次）。
///
/// 所以只要开了项目级 hook，每个事件都是双份。
final class HookDedupTests: XCTestCase {

    private func event(
        _ kind: HookEvent.Kind,
        session: String = "s1",
        prompt: String? = nil,
        toolUseId: String? = nil,
        lastMessage: String? = nil
    ) -> HookEvent {
        HookEvent(
            kind: kind,
            // requestId 每次 hubctl 调用都是新的 UUID —— **不能拿它当身份**，
            // 否则重复事件永远认不出来。这也是为什么 key 要按 kind 各自挑判据。
            requestId: UUID().uuidString,
            sessionId: session,
            cwd: "/tmp",
            lastAssistantMessage: lastMessage,
            promptText: prompt,
            toolUseId: toolUseId
        )
    }

    // MARK: - 基本去重

    func testSecondIdenticalEventIsADuplicate() throws {
        let dedup = HookDedup()
        let key = try XCTUnwrap(HookDedup.key(for: event(.userPromptSubmit, prompt: "改个 bug")))

        guard case .first = dedup.begin(key, waitForDecision: false) else {
            return XCTFail("第一条应该是 first")
        }
        dedup.finish(key, decision: .allow)

        guard case .duplicate = dedup.begin(key, waitForDecision: false) else {
            return XCTFail("第二条应该被认成重复")
        }
    }

    /// 内容不同就不是重复。
    ///
    /// 用户连着发两条不同的话是最正常不过的操作，误判成重复会让第二条
    /// 整个被吞掉 —— 原话收不到，验收清单的基线就缺了一块。
    func testDifferentPromptsAreNotDuplicates() throws {
        let dedup = HookDedup()
        let first = try XCTUnwrap(HookDedup.key(for: event(.userPromptSubmit, prompt: "改 A")))
        let second = try XCTUnwrap(HookDedup.key(for: event(.userPromptSubmit, prompt: "改 B")))

        XCTAssertNotEqual(first, second)
    }

    func testDifferentSessionsAreNotDuplicates() throws {
        let dedup = HookDedup()
        let a = try XCTUnwrap(HookDedup.key(for: event(.sessionEnd, session: "a")))
        let b = try XCTUnwrap(HookDedup.key(for: event(.sessionEnd, session: "b")))

        XCTAssertNotEqual(a, b)
        guard case .first = dedup.begin(a, waitForDecision: false) else {
            return XCTFail()
        }
        guard case .first = dedup.begin(b, waitForDecision: false) else {
            return XCTFail("另一个会话不该被当成重复")
        }
    }

    /// **收工事件刻意不去重。**
    ///
    /// 缓存决策只有在决策是事件的**纯函数**时才成立。preToolUse 满足
    /// （同一次工具调用永远同一个结论）；stop 不满足 —— 它取决于会变的上膛状态。
    ///
    /// 这条来自一次真实的端到端失败：先发一条未上膛的 stop（不拦），
    /// 再上膛、再发一条内容一模一样的 stop —— 第二条被当成副本，
    /// 复用了"不拦"的结论，**拦截静默失效**。
    ///
    /// 把 discriminator 改回 `lastAssistantMessage`，这条必须变红。
    func testStopIsDeliberatelyNotDeduplicated() {
        XCTAssertNil(
            HookDedup.key(for: event(.stop, lastMessage: "做完了")),
            "stop 的结论依赖上膛状态，不是事件的纯函数，不能缓存"
        )
    }

    /// 时间窗外的同样内容不算重复。
    ///
    /// 用户隔一会儿又发一遍「继续」是正常的，那是**两次**真实输入，
    /// 两次都该上膛。
    func testTheSameContentOutsideTheWindowIsNotADuplicate() throws {
        let dedup = HookDedup()
        let key = try XCTUnwrap(HookDedup.key(for: event(.userPromptSubmit, prompt: "继续")))
        let now = Date()

        _ = dedup.begin(key, waitForDecision: false, now: now)
        dedup.finish(key, decision: .allow, now: now)

        guard case .first = dedup.begin(key, waitForDecision: false, now: now.addingTimeInterval(30))
        else {
            return XCTFail("30 秒后的同样输入是新的一次，不能吞掉")
        }
    }

    // MARK: - 阻塞类事件必须拿到同一个决策
    //
    // 这一组是全类型里最要紧的。

    /// **重复的审批事件必须复用第一条的「拒绝」，不能自己放行。**
    ///
    /// 重复的那条如果简单跳过（什么都不返回 = 放行），而第一条判的是拒绝，
    /// 这次拒绝就被自己的副本架空了 —— 安全刹车被自己的影子松开，
    /// 是最不能接受的一类失败。
    func testDuplicateApprovalReusesTheDenial() throws {
        let dedup = HookDedup()
        let key = try XCTUnwrap(HookDedup.key(for: event(.preToolUse, toolUseId: "tu_1")))

        _ = dedup.begin(key, waitForDecision: true)
        dedup.finish(key, decision: HookDecision(verdict: .deny, reason: "用户拒绝了"))

        guard case .duplicate(let decision) = dedup.begin(key, waitForDecision: true) else {
            return XCTFail("应该被认成重复")
        }
        XCTAssertEqual(decision?.verdict, .deny)
        XCTAssertEqual(decision?.reason, "用户拒绝了")
    }

    /// 同一个工具调用的两条事件靠 tool_use_id 认亲。
    func testToolCallsAreIdentifiedByToolUseId() throws {
        let a = try XCTUnwrap(HookDedup.key(for: event(.preToolUse, toolUseId: "tu_1")))
        let b = try XCTUnwrap(HookDedup.key(for: event(.preToolUse, toolUseId: "tu_1")))
        let c = try XCTUnwrap(HookDedup.key(for: event(.preToolUse, toolUseId: "tu_2")))

        XCTAssertEqual(a, b, "同一次工具调用的两条事件必须同 key")
        XCTAssertNotEqual(a, c)
    }

    /// 副本比第一条先到齐时要等，不能各弹各的卡。
    func testAConcurrentDuplicateWaitsForTheFirstDecision() throws {
        let dedup = HookDedup()
        let key = try XCTUnwrap(HookDedup.key(for: event(.preToolUse, toolUseId: "tu_1")))

        guard case .first = dedup.begin(key, waitForDecision: true) else { return XCTFail() }

        let waited = expectation(description: "副本拿到了第一条的决策")
        DispatchQueue.global().async {
            guard case .duplicate(let decision) = dedup.begin(key, waitForDecision: true) else {
                return XCTFail("并发到达的副本应该被认成重复")
            }
            XCTAssertEqual(decision?.verdict, .deny)
            waited.fulfill()
        }

        // 让副本先卡在等待上，再给出决策。
        Thread.sleep(forTimeInterval: 0.2)
        dedup.finish(key, decision: HookDecision(verdict: .deny, reason: "慢慢想出来的"))

        wait(for: [waited], timeout: 5)
    }

    // MARK: - 不同类型的判据

    /// 一个会话只该开始一次、结束一次 —— 这几类用会话 id 就够。
    func testLifecycleEventsAreKeyedBySessionAlone() throws {
        let start = try XCTUnwrap(HookDedup.key(for: event(.sessionStart)))
        let same = try XCTUnwrap(HookDedup.key(for: event(.sessionStart)))
        let end = try XCTUnwrap(HookDedup.key(for: event(.sessionEnd)))

        XCTAssertEqual(start, same)
        XCTAssertNotEqual(start, end, "不同类型不能撞 key")
    }

    /// 除了工具类，每一类都要能算出 key。
    ///
    /// 算不出来（返回 nil）意味着那一类完全不去重 —— 加新 kind 时最容易漏的
    /// 就是这里，而漏了不会报错，只会在某天变成"通知弹两遍"。
    func testEveryNonToolKindProducesAKey() {
        let exempt: Set<HookEvent.Kind> = [.preToolUse, .postToolUse, .stop]
        for kind in HookChannelMonitor.expected where !exempt.contains(kind) {
            XCTAssertNotNil(
                HookDedup.key(for: event(kind)),
                "\(kind.rawValue) 算不出去重 key —— 加新 kind 时漏了 HookDedup.key"
            )
        }
    }

    /// **工具类事件缺了 tool_use_id 时必须放弃去重。**
    ///
    /// 这条看起来像在断言一个缺陷，其实是在钉死一个刻意的取舍。
    /// 退化成空串的话，Claude 连着快调的几个工具会算出同一个 key，
    /// 于是第二个工具的审批被当成"重复"直接复用第一个的结论 ——
    /// **安全刹车被自己的去重逻辑架空。**
    ///
    /// 宁可漏去重（多弹一张卡，用户骂两句），不可误去重（少拦一次，不可逆）。
    func testToolEventsWithoutAnIdentityAreNotDeduplicated() {
        XCTAssertNil(HookDedup.key(for: event(.preToolUse)))
        XCTAssertNil(HookDedup.key(for: event(.postToolUse)))
    }

    /// 有 tool_use_id 的正常情况照常去重。
    func testToolEventsWithAnIdentityAreDeduplicated() {
        XCTAssertNotNil(HookDedup.key(for: event(.preToolUse, toolUseId: "tu_1")))
    }
}
