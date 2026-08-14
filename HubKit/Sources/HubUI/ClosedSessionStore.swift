import Foundation
import Observation

/// 一个被结束掉的会话。
public struct ClosedSession: Codable, Sendable, Equatable, Identifiable {
    /// Claude 的 session UUID。**这是能不能接回来的全部依据** ——
    /// `claude --resume <id>` 认的就是它。
    public let sessionId: String
    public let name: String
    public let cwd: String
    public let endedAt: Date

    public var id: String { sessionId }

    public init(sessionId: String, name: String, cwd: String, endedAt: Date) {
        self.sessionId = sessionId
        self.name = name
        self.cwd = cwd
        self.endedAt = endedAt
    }
}

/// 被结束掉的会话名册。
///
/// ## 为什么杀之前必须先记下来
///
/// 「关窗即结束」这个选择只有在**还能再打开**的前提下才成立。用户的原话是
/// 「那我也打不开了呀」—— 一个只会杀不会还的回收器，把一个显示错误的会话
/// 换成了一个找不回来的会话，那不是修好，是换了个方式弄丢东西。
///
/// 好在会话本体不在进程里：Claude Code 一直把 transcript 写在
/// `~/.claude/projects/…/<sessionId>.jsonl`，进程杀掉不影响它。
/// 缺的只是**那个 id**，杀之前不记就真的没了 ——
/// 之后只能靠 `claude --resume` 的交互列表去人肉认，而那个列表里
/// 全是一模一样的项目名。
///
/// 所以这份名册是回收器的前置条件，不是附加功能。
@Observable
@MainActor
public final class ClosedSessionStore {

    /// 最近结束的在前。
    public private(set) var sessions: [ClosedSession] = []

    /// 留多少条。名册是给人「接着上次」用的，不是审计日志 ——
    /// 一个项目回头去接的几乎永远是最后那一个。
    private let limit = 40

    @ObservationIgnored private let url: URL?

    public nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/closed-sessions.json")
    }

    /// nil = 不落盘（测试用）。同仓库里其它几个 store 的理由：
    /// 路径写死会让测试直接改用户的真实数据。
    public init(url: URL? = ClosedSessionStore.defaultURL) {
        self.url = url
        load()
    }

    /// 记一笔。同一个 sessionId 只留最新的一条 —— 一个会话可以被
    /// resume、再被关掉、再 resume，重复记只会把名册塞满同一个东西。
    public func record(_ session: ClosedSession) {
        sessions.removeAll { $0.sessionId == session.sessionId }
        sessions.insert(session, at: 0)
        if sessions.count > limit { sessions.removeLast(sessions.count - limit) }
        persist()
    }

    /// 这个项目最近结束的那一个。
    ///
    /// 按 cwd 前缀匹配而不是相等：会话可能开在项目的子目录或 worktree 里，
    /// 只认相等会让「接着上次」在那些会话上凭空消失。
    public func latest(forProject path: String) -> ClosedSession? {
        sessions.first { Self.belongs(cwd: $0.cwd, project: path) }
    }

    static func belongs(cwd: String, project: String) -> Bool {
        cwd == project || cwd.hasPrefix(project + "/")
    }

    /// 已经重新开起来了就从名册里划掉 —— 留着会让界面同时显示
    /// 「在跑」和「上次结束于…」，用户不知道该信哪个。
    public func forget(sessionId: String) {
        guard sessions.contains(where: { $0.sessionId == sessionId }) else { return }
        sessions.removeAll { $0.sessionId == sessionId }
        persist()
    }

    // MARK: - 持久化

    private func load() {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ClosedSession].self, from: data)
        else { return }
        sessions = decoded
    }

    private func persist() {
        guard let url, let data = try? JSONEncoder().encode(sessions) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
