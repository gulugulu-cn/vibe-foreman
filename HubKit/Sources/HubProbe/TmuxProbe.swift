import Foundation

/// 一个 tmux pane 的拓扑信息。
public struct TmuxPane: Hashable, Sendable {
    public let sessionName: String
    public let windowId: String        // "@20"
    public let windowName: String      // 不可信，见下方说明
    public let paneId: String          // "%20"
    public let panePid: pid_t
    public let currentPath: String
    public let currentCommand: String

    public init(
        sessionName: String, windowId: String, windowName: String,
        paneId: String, panePid: pid_t, currentPath: String, currentCommand: String
    ) {
        self.sessionName = sessionName
        self.windowId = windowId
        self.windowName = windowName
        self.paneId = paneId
        self.panePid = panePid
        self.currentPath = currentPath
        self.currentCommand = currentCommand
    }
}

/// 采集 tmux 拓扑。
///
/// **窗口名不可信**：tmux 的 `automatic-rename` 会把 window_name 改成前台进程名，
/// 而 claude 的进程名就是它的版本号 —— 实测出现过窗口名变成 `2.1.173` 的情况。
/// 旧实现用 `窗口名 == projects.yaml 的 name` 判断项目是否在运行，实测 9 个窗口
/// 只有 2 个能匹配上。所以这里采集 windowName 只用于显示兜底，**绝不用于身份识别**。
/// 身份一律走 `panePid` → 进程树 → sessionId。
public struct TmuxProbe: Sendable {
    public let tmuxPath: String

    public init(tmuxPath: String? = nil) {
        self.tmuxPath = tmuxPath ?? Self.locateTmux()
    }

    /// tmux 可能装在 Homebrew（Apple Silicon / Intel 路径不同）或系统目录。
    /// GUI app 启动时不走 shell profile，PATH 里通常没有 /opt/homebrew/bin。
    private static func locateTmux() -> String {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/env"
    }

    private static let separator = "\u{1}"   // 用 SOH 而非 tab：路径里可能含 tab

    /// 列出全部 pane。tmux server 未运行时返回空数组（不是错误）。
    public func listPanes() -> [TmuxPane] {
        let format = [
            "#{session_name}", "#{window_id}", "#{window_name}", "#{pane_id}",
            "#{pane_pid}", "#{pane_current_path}", "#{pane_current_command}",
        ].joined(separator: Self.separator)

        let result = Shell.run(tmuxPath, ["list-panes", "-a", "-F", format], timeout: 3)
        guard result.succeeded else { return [] }

        return result.stdout.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: Self.separator)
            guard fields.count >= 7, let pid = pid_t(fields[4]) else { return nil }
            return TmuxPane(
                sessionName: fields[0],
                windowId: fields[1],
                windowName: fields[2],
                paneId: fields[3],
                panePid: pid,
                currentPath: fields[5],
                currentCommand: fields[6]
            )
        }
    }

    /// 当前有客户端连着的 tmux 会话名。
    ///
    /// 用来区分「会话真的在跑」和「会话在跑但终端已经关了」。这两种在进程层面
    /// 完全一样（claude 的父进程是 tmux server，关掉终端只是 detach，进程照活），
    /// 所以只看 `kill(pid, 0)` 会把已经关掉终端的会话报成在线 ——
    /// 用户看到的是「1 个会话」亮着蓝点，而他明明已经把窗口关了。
    ///
    /// tmux server 没跑时返回空集合（不是错误）。
    public func attachedSessionNames() -> Set<String> {
        let result = Shell.run(
            tmuxPath, ["list-clients", "-F", "#{client_session}"], timeout: 3
        )
        guard result.succeeded else { return [] }
        return Set(
            result.stdout
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    /// 把每个 pane 绑定到它承载的 Claude 会话 PID。
    ///
    /// 用**祖先链求交**而不是 `panePid == sessionPid` 直接相等：实测 8 个窗口里
    /// 有 2 个不成立（pane 的根进程是 shell，claude 是它的子进程）。
    /// 反过来 claude 也可能是 pane 根进程本身，所以从 panePid 起向上/向下都要覆盖 ——
    /// 这里的做法是：先看 panePid 自己是不是会话 PID，不是就看会话 PID 的祖先链里有没有 panePid。
    public func bindPanes(
        to sessionPIDs: Set<pid_t>,
        tree: ProcessTree,
        panes: [TmuxPane]? = nil
    ) -> [pid_t: TmuxPane] {
        let allPanes = panes ?? listPanes()
        var binding: [pid_t: TmuxPane] = [:]

        let paneByPid = Dictionary(allPanes.map { ($0.panePid, $0) }, uniquingKeysWith: { a, _ in a })

        for sessionPid in sessionPIDs {
            // 会话进程自身或其某个祖先，恰好是某个 pane 的根进程。
            for ancestor in tree.ancestry(of: sessionPid) {
                if let pane = paneByPid[ancestor] {
                    binding[sessionPid] = pane
                    break
                }
            }
        }
        return binding
    }
}
