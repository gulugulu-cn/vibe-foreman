import Foundation
import HubIPC

/// 同一个 hook 事件被送来两次时的去重。
///
/// ## 为什么必须有
///
/// Claude Code 的 hook 配置是**叠加**的，不是覆盖 —— 全局 `~/.claude/settings.json`
/// 和项目级 `.claude/settings.json` 里的同名 hook 会**都执行一遍**（本机实测确认：
/// 一次 `claude -p` 里项目级和全局的 UserPromptSubmit/Stop 各触发了一次）。
///
/// 于是把 `hubctl hook stop` 同时写进两处，一次收工就会有两条事件进来。后果不是
/// "多弹个通知"这么轻：
/// - 验收拦截的「上膛」会被第一条事件消费掉，第二条看到的是"没上膛"，拦截直接失效；
/// - 审批卡会为同一个操作弹两张。
///
/// 顺带它也挡住了另一类现实情况：用户机器上残留的旧配置、手动加过的重复条目。
///
/// ## 阻塞类事件为什么要缓存决策而不是简单跳过
///
/// PreToolUse 是阻塞的 —— hubctl 在等一个决策。重复的那条如果"跳过"（什么都不返回
/// = 放行），而第一条判的是拒绝，那这次拒绝就被自己的重复事件架空了。**安全刹车
/// 被自己的副本松开，是最不能接受的一类失败。** 所以重复的那条要等第一条的结果，
/// 拿到同一个决策。
final class HookDedup: @unchecked Sendable {

    enum Outcome {
        /// 第一次见到，照常处理。处理完必须调 `finish`。
        case first
        /// 重复事件。`decision` 是第一条已经得出的结论（还没出结论就等到了超时时为 nil）。
        case duplicate(HookDecision?)
    }

    /// 认定为"同一个事件"的时间窗。
    ///
    /// 叠加触发的两条几乎是同时到的，5 秒远远够用。窗口再大就有误伤风险：
    /// 用户连着发两条一模一样的短消息（"继续"、"继续"）是完全正常的操作。
    private let window: TimeInterval = 5

    private let lock = NSLock()
    private var settled: [String: (at: Date, decision: HookDecision)] = [:]
    private var inFlight: [String: DispatchSemaphore] = [:]

    /// 事件的身份。nil = 这类事件无法可靠区分，不做去重（宁可重复也不能误杀）。
    static func key(for event: HookEvent) -> String? {
        let discriminator: String?
        switch event.kind {
        case .preToolUse, .postToolUse:
            // tool_use_id 是每次工具调用唯一的，是最可靠的判据。
            //
            // **两个都没有时必须返回 nil（= 不去重），绝不能退化成空串。**
            // Claude 会连着快速调好几个工具，它们的 key 会因为空串而全部相同 ——
            // 于是第二个工具的审批被当成"重复"直接复用第一个的结论。
            // 安全刹车被自己的去重逻辑架空，是最不能接受的一类失败。
            // 宁可漏去重（多弹一张卡），不可误去重（少拦一次）。
            discriminator = event.toolUseId ?? event.toolSummary
        case .userPromptSubmit:
            // 空输入退化成空串是安全的：5 秒内两条空输入吞掉一条没有任何损失。
            discriminator = event.promptText ?? ""
        case .stop:
            // **刻意不去重。**
            //
            // 缓存决策只有在决策是事件的**纯函数**时才成立。preToolUse 满足
            // （同一次工具调用永远同一个结论），stop 不满足 —— 它取决于会变的
            // 上膛状态：同样内容的两条 stop，一条在用户说话前、一条在之后，
            // 结论截然相反。
            //
            // 实测踩到过：先发一条未上膛的 stop（不拦），再上膛、再发一条内容
            // 一模一样的 stop —— 第二条被当成副本，复用了"不拦"，拦截静默失效。
            //
            // 不去重的代价只是重复 stop 会多发一条通知，而重复 stop 本来就
            // 几乎不会发生（相同命令 Claude Code 自己会去重）。上膛机制自身
            // 也是安全的：第一条消费掉膛，第二条自然看到未上膛。
            discriminator = nil
        case .notification:
            discriminator = event.message ?? event.notificationType ?? ""
        case .sessionStart, .sessionEnd, .subagentStop, .preCompact:
            // 这几类一个会话里本来就只该来一次，会话 id 足够。
            discriminator = ""
        }
        guard let discriminator else { return nil }
        return "\(event.kind.rawValue)|\(event.sessionId)|\(discriminator.hashValue)"
    }

    /// 登记一条事件。
    ///
    /// - Parameter waitForDecision: 阻塞类事件（PreToolUse）传 true —— 重复的那条会
    ///   等第一条出结果，拿到同一个决策。非阻塞类传 false，重复的直接返回。
    func begin(_ key: String, waitForDecision: Bool, now: Date = Date()) -> Outcome {
        lock.lock()

        if let previous = settled[key], now.timeIntervalSince(previous.at) < window {
            lock.unlock()
            return .duplicate(previous.decision)
        }

        if let semaphore = inFlight[key] {
            lock.unlock()
            guard waitForDecision else { return .duplicate(nil) }
            // 第一条还在等用户决策 —— 跟着一起等，别自己去弹第二张卡。
            _ = semaphore.wait(timeout: .now() + HookTimeouts.serverBridge)
            lock.lock()
            let decision = settled[key]?.decision
            lock.unlock()
            return .duplicate(decision)
        }

        inFlight[key] = DispatchSemaphore(value: 0)
        // 顺带清掉过期的，省得无限长。会话可以开几天，这个表不能只进不出。
        settled = settled.filter { now.timeIntervalSince($0.value.at) < window }
        lock.unlock()
        return .first
    }

    /// 第一条处理完了，把结论留给可能正在等的副本。
    func finish(_ key: String, decision: HookDecision, now: Date = Date()) {
        lock.lock()
        settled[key] = (now, decision)
        let semaphore = inFlight.removeValue(forKey: key)
        lock.unlock()
        // 唤醒所有在等的副本。信号量按等待方数量补齐即可，多补几次无害。
        for _ in 0..<8 { semaphore?.signal() }
    }
}
