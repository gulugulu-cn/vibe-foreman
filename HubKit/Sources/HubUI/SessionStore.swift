import Foundation
import HubCore
import HubJump
import HubProbe
import HubProjects

/// 全部 agent 会话的实时快照。岛和主窗口共享同一个实例。
///
/// 数据来自 `~/.claude/sessions/*.json` —— Claude Code 自己维护的权威状态源。
/// 这里只做读取、排序和跳转派发，不做任何状态推断。
@Observable
@MainActor
public final class SessionStore {

    public private(set) var sessions: [AgentSession] = []
    public private(set) var lastRefresh: Date = .distantPast

    /// sessionId → 人能看懂的终端位置（"iTerm · storefront-a"、"tmux · @12"）。
    ///
    /// 详情卡要回答"这个会话在哪儿能找到"，但解析它要跑 AppleScript + tmux 子进程，
    /// 每次渲染都算是不可接受的。所以在后台按需解析、缓存下来，视图只读缓存。
    public private(set) var terminalLabels: [String: String] = [:]

    /// cwd → 该工作区的 git 快照（分支、变更数、最近提交）。
    ///
    /// 按 **cwd** 而不是按 projects.yaml 里的项目采集：会话可能开在任意目录、
    /// 任意 worktree，甚至根本没登记过。同一个项目多开时，分支和仓库根目录
    /// 是区分它们的主要依据 —— 只显示项目名会把几个会话糊成一个。
    public private(set) var workspaceGit: [String: WorkspaceGit] = [:]

    /// 最近一次跳转的结果。跳转是异步的，成功与否必须回显，
    /// 否则用户点完只能靠"终端有没有跳过去"自己猜。
    public private(set) var lastJump: (sessionId: String, outcome: JumpOutcome)?

    private let reader: ClaudeSessionReader
    private let jumpEngine: JumpEngine
    private var timer: Timer?
    private var resolvingTerminals = false
    private var lastTerminalResolve: Date = .distantPast
    private var resolvingGit = false
    private var lastGitResolve: Date = .distantPast

    public init(
        reader: ClaudeSessionReader = ClaudeSessionReader(),
        jumpEngine: JumpEngine = JumpEngine()
    ) {
        self.reader = reader
        self.jumpEngine = jumpEngine
    }

    // MARK: - 派生数据

    public var waitingCount: Int { sessions.count { $0.status == .waiting } }
    public var busyCount: Int { sessions.count { $0.status == .busy } }
    public var shellCount: Int { sessions.count { $0.status == .shell } }
    public var idleCount: Int { sessions.count { $0.status == .idle } }

    /// 有没有活跃会话。决定像素小人的时钟频率和轮询节奏。
    public var hasActiveSessions: Bool { sessions.contains { $0.status.isActive } }

    /// 最紧急的那个会话。折叠态的徽章和闯入态都用它。
    public var mostUrgent: AgentSession? { sessions.first { $0.status == .waiting } }

    // MARK: - 刷新

    /// 轮询间隔自适应。
    ///
    /// `sessions/*.json` 的写入频率跟着 Claude 的活动走，全空闲时几分钟才动一次，
    /// 这时候还每秒扫一遍纯属浪费 —— 常驻 app 的耗电就是这么攒出来的。
    ///
    /// 后续会换成 `DispatchSource` 监听目录做到近实时；轮询是先跑起来的过渡实现。
    private var refreshInterval: TimeInterval {
        if waitingCount > 0 { return 1.0 }
        if hasActiveSessions { return 2.0 }
        return 5.0
    }

    public func start() {
        refresh()
        scheduleNext()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: refreshInterval, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.scheduleNext()
            }
        }
    }

    public func refresh() {
        let fresh = reader.readAll()
        let sorted = Self.sort(fresh)
        // 只在真的变了时才赋值：@Observable 的写入会触发 SwiftUI 重绘，
        // 每秒无脑重绘 9 行列表是没必要的开销。
        if sorted != sessions {
            sessions = sorted
        }
        lastRefresh = Date()
    }

    /// 排序即 UI 优先级。
    ///
    /// 不按项目分组作默认：9 个会话跨 5 个项目，按项目排会让
    /// 「哪个在等我」这个最高频的问题需要扫描整个列表。
    static func sort(_ input: [AgentSession]) -> [AgentSession] {
        input.sorted { lhs, rhs in
            // ① 状态优先级：waiting → busy → shell → idle → unknown
            if lhs.status != rhs.status { return lhs.status < rhs.status }

            // ② waiting 组内：等得最久的排最上（催得最急的先处理）
            if lhs.status == .waiting {
                let l = lhs.statusUpdatedAt ?? .distantPast
                let r = rhs.statusUpdatedAt ?? .distantPast
                if l != r { return l < r }
            }

            // ③ 其余：最近活跃的在上
            let l = lhs.updatedAt ?? .distantPast
            let r = rhs.updatedAt ?? .distantPast
            if l != r { return l > r }

            // ④ interactive 优先于 bg
            if lhs.kind != rhs.kind { return lhs.kind == .interactive }

            // ⑤ 兜底用 sessionId 保证顺序稳定，避免列表无谓抖动
            return lhs.sessionId < rhs.sessionId
        }
    }

    // MARK: - 终端定位

    /// 解析每个会话在哪个终端里，结果缓存到 `terminalLabels`。
    ///
    /// 展开岛的时候调一次即可。有 12 秒的节流：解析要跑 AppleScript 遍历 iTerm
    /// 全部 session 再加一次 `tmux list-panes`，几十到几百毫秒，不该跟着渲染走。
    public func resolveTerminalLabels(force: Bool = false) {
        guard !resolvingTerminals else { return }
        if !force, Date().timeIntervalSince(lastTerminalResolve) < 12 { return }
        resolvingTerminals = true

        let snapshot = sessions
        Task.detached(priority: .utility) { [weak self] in
            let labels = Self.computeTerminalLabels(for: snapshot)
            await MainActor.run {
                guard let self else { return }
                self.terminalLabels = labels
                self.lastTerminalResolve = Date()
                self.resolvingTerminals = false
            }
        }
    }

    /// 纯计算部分，跑在后台线程。
    ///
    /// 两条线索：iTerm 的 `jobPid` 祖先链（能定位到具体 tab），
    /// 以及 tmux 的 `pane_pid` 祖先链（能给出窗口名）。两者都拿不到的
    /// `bg` 会话本来就不在任何终端里 —— 如实说，别编一个位置出来。
    nonisolated static func computeTerminalLabels(
        for sessions: [AgentSession]
    ) -> [String: String] {
        guard !sessions.isEmpty else { return [:] }

        let tree = ProcessTree.snapshot()
        var labels: [String: String] = [:]

        if ITermLocator.isRunning() {
            let terms = ITermLocator().snapshot()
            let bound = JumpEngine.bind(
                itermSessions: terms, claudeSessions: sessions, tree: tree
            )
            let nameByUUID = Dictionary(
                terms.map { ($0.sessionUUID, $0.name) }, uniquingKeysWith: { a, _ in a }
            )
            for (sessionId, uuid) in bound {
                let name = nameByUUID[uuid] ?? ""
                labels[sessionId] = name.isEmpty ? "iTerm" : "iTerm · \(name)"
            }
        }

        let pids = Set(sessions.map(\.pid))
        let panes = TmuxProbe().bindPanes(to: pids, tree: tree)
        if !panes.isEmpty {
            let sessionIdByPid = Dictionary(
                sessions.map { ($0.pid, $0.sessionId) }, uniquingKeysWith: { a, _ in a }
            )
            for (pid, pane) in panes {
                guard let sessionId = sessionIdByPid[pid] else { continue }
                let tmuxLabel = "tmux · \(pane.sessionName):\(pane.windowName)"
                // iTerm 的定位更精确（能点到具体 tab），tmux 信息作为补充拼在后面。
                labels[sessionId] = labels[sessionId].map { "\($0)  ·  \(tmuxLabel)" }
                    ?? tmuxLabel
            }
        }

        for session in sessions where labels[session.sessionId] == nil {
            labels[session.sessionId] = session.kind == .bg ? "后台任务，不在终端里" : "未定位到终端"
        }
        return labels
    }

    // MARK: - 工作区 git

    /// 解析这些 cwd 的 git 快照。展开岛时调，内部按 cwd 去重 + 10 秒节流。
    public func resolveWorkspaceGit(for paths: [String], force: Bool = false) {
        let wanted = Set(paths)
        let missing = force ? wanted : wanted.filter { workspaceGit[$0] == nil }
        let stale = force || Date().timeIntervalSince(lastGitResolve) > 10
        guard !missing.isEmpty || stale else { return }
        guard !resolvingGit else { return }

        let targets = Array(stale ? wanted : missing)
        guard !targets.isEmpty else { return }
        resolvingGit = true

        Task.detached(priority: .utility) { [weak self] in
            var collected: [String: WorkspaceGit] = [:]
            for path in targets {
                guard let root = GitStatus.repositoryRoot(at: path),
                      let info = GitStatus.collect(at: path)
                else { continue }
                collected[path] = WorkspaceGit(
                    root: root, info: info, recent: GitStatus.log(at: path, limit: 3)
                )
            }
            await MainActor.run { [collected] in
                guard let self else { return }
                self.workspaceGit.merge(collected) { _, new in new }
                self.lastGitResolve = Date()
                self.resolvingGit = false
            }
        }
    }

    // MARK: - 动作

    /// 跳到会话所在的终端 tab。
    ///
    /// AppleScript 有跨进程成本，放后台线程跑，别卡住 UI。结果写回
    /// `lastJump` 供 UI 回显 —— 只写日志的话用户看不到任何反馈。
    public func jump(to sessionId: String, then: (@MainActor (JumpOutcome) -> Void)? = nil) {
        let engine = jumpEngine
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = engine.jump(to: sessionId)
            if case .failed(let reason) = outcome {
                NSLog("[ClaudeHub] 跳转失败: \(reason)")
            }
            await MainActor.run {
                self?.lastJump = (sessionId, outcome)
                then?(outcome)
            }
        }
    }
}
