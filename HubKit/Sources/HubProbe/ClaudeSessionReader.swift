import Foundation
import HubCore

/// 读取 `~/.claude/sessions/<PID>.json`。
///
/// 这是本项目的**权威状态源** —— Claude Code 自己在维护它，含 `busy` / `idle` /
/// `waiting` / `shell` 以及 waiting 的原因。旧实现靠 Stop hook 事件反推状态，
/// 既有延迟又拿不到 waiting；更早的设计里还考虑过用 pane_title 的 spinner 字符猜
/// busy —— 有了这个文件之后，那些启发式全都不需要了。
public struct ClaudeSessionReader: Sendable {
    public let directory: URL

    /// 是否要求对应进程还活着。
    ///
    /// 生产必须为 true —— 目录里残留着好几天前已退出进程的 json，不过滤
    /// 岛上就会显示一堆幽灵会话。**只有演示模式**（合成数据，进程当然不存在）
    /// 才关掉它。
    public let requiresLiveProcess: Bool

    public init(directory: URL? = nil, requiresLiveProcess: Bool = true) {
        self.directory = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
        self.requiresLiveProcess = requiresLiveProcess
    }

    /// 读取全部存活会话。
    ///
    /// - Parameter isAlive: 判活谓词，测试时可注入。默认 `kill(pid, 0)`。
    ///   **必须过滤**：实测目录里残留着好几天前已退出进程的 json，
    ///   不过滤岛上就会显示一堆幽灵会话。
    public func readAll(
        isAlive: (pid_t) -> Bool = ProcessTree.isAlive
    ) -> [AgentSession] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var sessions: [String: AgentSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = AgentSession.decode(from: data),
                  !requiresLiveProcess || isAlive(session.pid)
            else { continue }

            // 同一 sessionId 可能有多个 PID 文件（resume 后旧进程的 json 尚未清理，
            // 且旧 PID 恰好被系统复用给了别的进程从而通过判活）。留 updatedAt 最新的那个。
            if let existing = sessions[session.sessionId] {
                let lhs = session.updatedAt ?? .distantPast
                let rhs = existing.updatedAt ?? .distantPast
                if lhs <= rhs { continue }
            }
            sessions[session.sessionId] = session
        }
        return Array(sessions.values)
    }

    /// 存活会话的 PID 集合。跳转时用来判断某个祖先 PID 是不是 Claude 会话。
    public func alivePIDs(
        isAlive: (pid_t) -> Bool = ProcessTree.isAlive
    ) -> Set<pid_t> {
        Set(readAll(isAlive: isAlive).map(\.pid))
    }
}
