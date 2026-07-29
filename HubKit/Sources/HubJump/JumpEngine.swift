import Foundation
import HubCore
import HubProbe

/// 跳转结果。失败时带上原因，便于 UI 给用户一个可行动的提示，
/// 而不是像旧实现那样静默什么都不做。
public enum JumpOutcome: Equatable, Sendable {
    /// 成功切到目标 tab。`strategy` 记录哪级策略生效，用于观察降级频率。
    case focused(strategy: String)
    /// 会话不在任何已知终端里（比如它跑在 VS Code 内置终端）。已尽力前置终端 app。
    case terminalActivatedOnly(reason: String)
    case failed(reason: String)
}

/// 从 `sessionId` 精准跳到承载它的终端 tab。
///
/// ## 为什么旧实现是坏的
///
/// 旧链路是「项目名 → tmux 窗口名 → pane_title → AppleScript 按标题子串匹配」，
/// 三段全是会漂移的字符串：
/// - tmux `automatic-rename` 会把窗口名改成前台进程名（claude 的进程名是版本号，
///   实测出现过窗口名变成 `2.1.173`）；
/// - `pane_title` 是 claude 的会话标题，**每轮回复都在变**，还带 spinner 前缀；
///   旧代码只剥了盲文 spinner（U+2800–U+28FF），漏了 `✳`（U+2733）；
/// - 多个会话的标题都可能是通用的 "Claude Code"，子串匹配会撞车跳错。
///
/// ## 现在的做法
///
/// iTerm 报告每个 session 的 `jobPid`，从它向上走进程树，第一个存在
/// `~/.claude/sessions/<PID>.json` 的祖先就是该 tab 承载的会话。全程只用整数 PID
/// 和 UUID，没有任何字符串匹配。实测同时覆盖 tmux `-CC` 会话与非 tmux 原生会话。
public struct JumpEngine: Sendable {
    private let iterm: ITermLocator
    private let sessionReader: ClaudeSessionReader
    private let tmux: TmuxProbe

    public init(
        iterm: ITermLocator = ITermLocator(),
        sessionReader: ClaudeSessionReader = ClaudeSessionReader(),
        tmux: TmuxProbe = TmuxProbe()
    ) {
        self.iterm = iterm
        self.sessionReader = sessionReader
        self.tmux = tmux
    }

    /// bg 会话按名字绑定时要求的最短名字长度。
    ///
    /// 太短的名字（如 `api`）在别的 tab 标题里偶然出现的概率不可忽略。
    /// Claude 派生的 job 名实测都是十几到几十字符的 slug，这个门槛不会误伤。
    private static let minimumNameLengthForTitleBinding = 8

    /// 建立 `Claude sessionId` → `iTerm session UUID` 的映射。
    ///
    /// 纯函数式的核心逻辑独立出来，方便单测注入假数据 —— AppleScript 和 sysctl
    /// 都没法在 CI 里跑，但这段绑定逻辑正是最容易出错、最需要测试的部分。
    ///
    /// 分两轮：
    /// 1. **祖先链**（主策略，覆盖全部 `interactive` 会话）；
    /// 2. **job 名匹配**（只兜 `bg` 会话，见下方说明）。
    public static func bind(
        itermSessions: [ITermSession],
        claudeSessions: [AgentSession],
        tree: ProcessTree
    ) -> [String: String] {
        guard !claudeSessions.isEmpty else { return [:] }

        let sessionByPid = Dictionary(
            claudeSessions.map { ($0.pid, $0.sessionId) },
            uniquingKeysWith: { a, _ in a }
        )

        var mapping: [String: String] = [:]
        var consumedTerms = Set<String>()

        // 第一轮：祖先链。iTerm 报的 jobPid 向上走，第一个是 Claude 会话的祖先即所有者。
        for term in itermSessions {
            guard let ownerPid = tree.firstAncestor(of: term.jobPid, where: {
                sessionByPid[$0] != nil
            }), let claudeId = sessionByPid[ownerPid] else { continue }

            // 一个 Claude 会话理论上只对应一个 iTerm session。真出现多个
            // （分屏里 attach 了同一个 tmux window），取第一个即可 —— 它们指向同一处。
            if mapping[claudeId] == nil {
                mapping[claudeId] = term.sessionUUID
                consumedTerms.insert(term.sessionUUID)
            }
        }

        // 第二轮：bg 会话。
        //
        // `kind: bg` 的会话跑在 `claude bg-pty-host` daemon 下，**不在任何终端里**，
        // 祖先链必然连不上（实测祖先链是 claude bg-spare → bg-pty-host → claude daemon）。
        // 用户能看到它的地方是某个跑着 `claude agents` 的 tab，那是个查看器进程，
        // 与后台会话之间没有任何父子关系。
        //
        // 查看器会把 job 名写进 tab 标题（`o3-ui-memory-idempotent-fixes (Claude)`）。
        // 这里**破例用标题匹配** —— 但和旧实现按 `pane_title` 匹配有本质区别：
        // 旧实现匹配的是 ai-title，每轮回复都在变；而 bg 会话的 `name` 是创建时
        // 一次性派生的稳定 slug，全程不变。加上只在第一轮未绑定的 tab 里找、
        // 且要求名字足够长，误绑风险很低。
        let unboundBg = claudeSessions.filter {
            $0.kind == .bg && mapping[$0.sessionId] == nil
        }
        guard !unboundBg.isEmpty else { return mapping }

        for session in unboundBg {
            guard let name = session.name,
                  name.count >= minimumNameLengthForTitleBinding
            else { continue }

            let match = itermSessions.first {
                !consumedTerms.contains($0.sessionUUID) && $0.name.contains(name)
            }
            if let match {
                mapping[session.sessionId] = match.sessionUUID
                consumedTerms.insert(match.sessionUUID)
            }
        }
        return mapping
    }

    /// 跳到指定会话所在的终端 tab。
    public func jump(to sessionId: String) -> JumpOutcome {
        guard ITermLocator.isRunning() else {
            return .failed(reason: "iTerm2 未运行")
        }

        let claudeSessions = sessionReader.readAll()
        guard claudeSessions.contains(where: { $0.sessionId == sessionId }) else {
            return .failed(reason: "会话 \(sessionId) 已不存在")
        }

        // 策略 A：jobPid 祖先链匹配。已实测验证，覆盖 tmux -CC 与非 tmux 会话。
        let tree = ProcessTree.snapshot()
        let itermSessions = iterm.snapshot()
        let mapping = Self.bind(
            itermSessions: itermSessions,
            claudeSessions: claudeSessions,
            tree: tree
        )

        if let target = mapping[sessionId] {
            if iterm.focus(sessionUUID: target) {
                // 验证：跳完再问一次前台是谁。AppleScript 的 select 在极少数情况下
                // 会被 iTerm 自己的焦点逻辑覆盖（-CC 模式尤其），不验证就会谎报成功。
                if let front = iterm.frontmostSessionUUID(), front == target {
                    return .focused(strategy: "A/jobPid")
                }
                return .focused(strategy: "A/jobPid(未验证)")
            }
        }

        // 策略 C：会话在 tmux 里但 iTerm 侧没绑上（比如 iTerm 没 attach 这个 session）。
        // 让 tmux 自己切窗口。注意 iTerm -CC 模式下这一步会被 iTerm 覆盖，
        // 所以它只对「非 iTerm 终端 attach 的 tmux」有效，这里作为降级尝试。
        let panes = tmux.listPanes()
        let sessionPIDs = Set(claudeSessions.map(\.pid))
        let binding = tmux.bindPanes(to: sessionPIDs, tree: tree, panes: panes)
        if let session = claudeSessions.first(where: { $0.sessionId == sessionId }),
           let pane = binding[session.pid] {
            let result = Shell.run(
                tmux.tmuxPath, ["select-window", "-t", pane.windowId], timeout: 3
            )
            if result.succeeded {
                _ = Shell.osascript(#"tell application "iTerm2" to activate"#, timeout: 4)
                return .terminalActivatedOnly(
                    reason: "已切 tmux 窗口 \(pane.windowId)，但 iTerm 侧未能精确定位 tab"
                )
            }
        }

        // 兜底：至少把终端拉到前台，别让用户点了毫无反应。
        _ = Shell.osascript(#"tell application "iTerm2" to activate"#, timeout: 4)
        return .terminalActivatedOnly(reason: "未能定位该会话所在的 tab，仅前置 iTerm2")
    }
}
