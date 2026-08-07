import Foundation
import HubIPC
import Observation

/// 每类 hook 通道的健康度。
///
/// ## 为什么需要它
///
/// `hubctl doctor` 只能回答"socket 通不通"。但 hook 链路断掉的方式远不止这一种：
/// - `~/.claude/settings.json` 里某一类 hook 被别的工具覆盖掉了；
/// - 项目级配置写错了 event 名字（`PostToolUse` 拼成 `PostToolUSE`）；
/// - 用户升级了 Claude Code，某个 event 改了名。
///
/// 这几种情况下 socket 是通的、doctor 是绿的，但那一类事件**一条都收不到** ——
/// 而验收清单会安静地不工作。「配置里有」和「真的在通」是两回事，
/// 只有真收到过事件才能证明后者。
@Observable
@MainActor
public final class HookChannelMonitor {

    public private(set) var lastSeen: [HookEvent.Kind: Date] = [:]
    public private(set) var counts: [HookEvent.Kind: Int] = [:]

    public init() {}

    public func record(_ kind: HookEvent.Kind) {
        lastSeen[kind] = Date()
        counts[kind, default: 0] += 1
    }

    /// 所有应该被装上的通道。UI 按这个列表逐条显示"通了没"。
    ///
    /// nonisolated：它是一份常量清单，跟 actor 状态无关，
    /// 而 `setup-swift-hooks.sh` 装了哪几类要能被测试拿来比对。
    public nonisolated static let expected: [HookEvent.Kind] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse,
        .notification, .stop, .subagentStop, .preCompact, .sessionEnd,
    ]

    public nonisolated static func label(for kind: HookEvent.Kind) -> String {
        switch kind {
        case .sessionStart: return "会话开始"
        case .userPromptSubmit: return "用户提交"
        case .preToolUse: return "工具调用前"
        case .postToolUse: return "工具调用后"
        case .notification: return "通知"
        case .stop: return "收工"
        case .subagentStop: return "子 agent 收工"
        case .preCompact: return "上下文压缩前"
        case .sessionEnd: return "会话结束"
        }
    }
}
