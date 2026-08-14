import Foundation
import HubCore
import HubProbe

/// 「哪些会话已经没终端连着了」。
///
/// 关掉终端窗口**不会**结束会话：claude 的父进程是 tmux server，关窗口只是
/// detach，进程照跑，`kill(pid, 0)` 依然为真。所以判活判不出这件事，
/// 得去问 tmux 有没有客户端连着。
///
/// 这份判定有两个消费方（界面上的标记、自动回收），**必须是同一份** ——
/// 两边各写一遍的话，回收器杀的和界面标的迟早对不上，
/// 而那种不一致的表现是"它杀了一个界面上显示正常的会话"。
enum DetachedSessions {

    /// 没有客户端连着的会话，连同它所在的 pane。
    ///
    /// **绑不到 pane 的一律不算。** 那是「根本不在 tmux 里」（VS Code 扩展、
    /// 直接开的终端、bg 任务），它们有没有终端连着这里判断不了。
    /// 硬报成 detached 就是拿"不知道"当结论 —— 界面上会让一批正常会话集体
    /// 显示成"终端已关"，回收器则会去杀它们，而它们压根不归 tmux 管。
    static func pairs(
        sessions: [AgentSession],
        panes: [TmuxPane],
        attached: Set<String>,
        tree: ProcessTree
    ) -> [(session: AgentSession, pane: TmuxPane)] {
        guard !sessions.isEmpty, !panes.isEmpty else { return [] }

        let bound = TmuxProbe().bindPanes(
            to: Set(sessions.map(\.pid)), tree: tree, panes: panes
        )
        let sessionByPid = Dictionary(
            sessions.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a }
        )

        // **按 tmux 会话名逐个判，不是「有没有任何客户端」。**
        // 客户端可能连在另一个 tmux 会话上，那对这个 pane 而言等于没连。
        return bound.compactMap { pid, pane in
            guard !attached.contains(pane.sessionName),
                  let session = sessionByPid[pid]
            else { return nil }
            return (session, pane)
        }
    }
}
