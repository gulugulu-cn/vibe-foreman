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

    /// 进程还活着、但承载它的 tmux 会话已经没有任何客户端连着的会话。
    ///
    /// ## 为什么必须单独有这一档
    ///
    /// 关掉终端窗口**不会**结束会话：claude 的父进程是 tmux server，关窗口
    /// 只是 detach，进程照跑。于是 `kill(pid, 0)` 依然为真，界面上一直亮着
    /// 「1 个会话」的蓝点，而用户明明已经把窗口关了 —— 他会认为界面在撒谎。
    ///
    /// 真相是「还在跑，只是没终端连着」。这两件事都要说，少说哪一半都不对：
    /// 报成已退出会掩盖一个还在烧 token 的进程，报成在线又和用户看到的相反。
    public private(set) var detachedSessionIds: Set<String> = []

    /// cwd → 该工作区的 git 快照（分支、变更数、最近提交）。
    ///
    /// 按 **cwd** 而不是按 projects.yaml 里的项目采集：会话可能开在任意目录、
    /// 任意 worktree，甚至根本没登记过。同一个项目多开时，分支和仓库根目录
    /// 是区分它们的主要依据 —— 只显示项目名会把几个会话糊成一个。
    public private(set) var workspaceGit: [String: WorkspaceGit] = [:]

    /// 最近一次跳转的结果。跳转是异步的，成功与否必须回显，
    /// 否则用户点完只能靠"终端有没有跳过去"自己猜。
    public private(set) var lastJump: (sessionId: String, outcome: JumpOutcome)?

    /// sessionId → 上一轮活干了多久（一次完整的 busy/shell → idle/waiting）。
    ///
    /// 滞留提醒**按这个分级**：干了半小时的活值得主动打断你去验收，
    /// 干了半分钟的不值得 —— 同时跑七八个会话时，小活也弹会立刻变成骚扰。
    ///
    /// 为什么必须自己观测：Claude 自己在界面上显示的 "Crunched for 29m 54s"
    /// 不落到任何我们能读的文件里。`sessions/<PID>.json` 只有当前状态和
    /// 状态变更时刻，推不出上一段状态持续了多久。
    ///
    /// app 重启会丢，这是可以接受的 —— 丢了就退化成"不知道"，
    /// 而 `StallDetector` 对"不知道"的处理是按高优，不会漏报。
    public private(set) var lastWorkDuration: [String: TimeInterval] = [:]

    /// sessionId → 这一轮 busy 是什么时候开始的。只在观测期间有值。
    private var workStartedAt: [String: Date] = [:]

    private let reader: ClaudeSessionReader
    private let jumpEngine: JumpEngine
    private var timer: Timer?
    private var resolvingTerminals = false
    private var lastTerminalResolve: Date = .distantPast
    private var resolvingGit = false
    private var lastGitResolve: Date = .distantPast
    private var resolvingDetached = false
    private var lastDetachedResolve: Date = .distantPast

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
        observeWorkDurations(sorted)
        // 只在真的变了时才赋值：@Observable 的写入会触发 SwiftUI 重绘，
        // 每秒无脑重绘 9 行列表是没必要的开销。
        if sorted != sessions {
            sessions = sorted
        }
        lastRefresh = Date()
        resolveDetached()
    }

    /// 刷新「哪些会话已经没终端连着」。
    ///
    /// 跟着 refresh 走而不是等界面展开：这个标记决定项目列表上那颗点的颜色，
    /// 而项目列表在主窗口一打开就在看着 —— 等展开才算的话，用户看到的
    /// 第一眼仍然是错的。
    ///
    /// 要跑两个 tmux 子进程，所以 5 秒节流。refresh 最快 1 秒一轮，
    /// 不节流就是每秒 fork 两次。
    private func resolveDetached() {
        if DemoFixtures.isEnabled { return }
        guard !resolvingDetached else { return }
        guard Date().timeIntervalSince(lastDetachedResolve) >= 5 else { return }

        let snapshot = sessions
        guard !snapshot.isEmpty else {
            if !detachedSessionIds.isEmpty { detachedSessionIds = [] }
            return
        }
        resolvingDetached = true

        Task.detached(priority: .utility) { [weak self] in
            let probe = TmuxProbe()
            // 探测失败（nil）就沿用上一轮的判定，别把"不知道"画成
            // "终端已关" —— 那会让一批正常会话集体闪成灰的，
            // 而且和回收器的判据必须是同一份（见 `DetachedSessions`）。
            let ids = probe.attachedSessionNames().map { attached in
                Self.detachedIds(
                    sessions: snapshot,
                    panes: probe.listPanes(),
                    attached: attached,
                    tree: ProcessTree.snapshot()
                )
            }
            await MainActor.run {
                guard let self else { return }
                if let ids, self.detachedSessionIds != ids { self.detachedSessionIds = ids }
                if ids != nil { self.lastDetachedResolve = Date() }
                self.resolvingDetached = false
            }
        }
    }

    /// 纯计算：哪些会话所在的 tmux 会话没有客户端连着。
    ///
    /// 判定本体在 `DetachedSessions` —— **回收器用的必须是同一份**，
    /// 否则会出现"它杀了一个界面上显示正常的会话"。
    nonisolated static func detachedIds(
        sessions: [AgentSession],
        panes: [TmuxPane],
        attached: Set<String>,
        tree: ProcessTree
    ) -> Set<String> {
        Set(
            DetachedSessions.pairs(
                sessions: sessions, panes: panes, attached: attached, tree: tree
            ).map(\.session.sessionId)
        )
    }

    /// 观测 busy → idle 的跃迁，记下这一轮活干了多久。
    ///
    /// 必须在 `sessions` 被覆盖**之前**调用 —— 它要拿旧快照做对比。
    ///
    /// 用 `statusUpdatedAt` 而不是"我们发现它变了"的墙钟时间：轮询间隔在
    /// 全空闲时是 5 秒，用发现时刻算会把误差累进时长里；而 `statusUpdatedAt`
    /// 是 Claude 自己写的状态变更时刻，精确得多。
    private func observeWorkDurations(_ fresh: [AgentSession]) {
        let previous = Dictionary(
            sessions.map { ($0.sessionId, $0.status) }, uniquingKeysWith: { a, _ in a }
        )

        for session in fresh {
            let wasWorking = previous[session.sessionId]?.isWorking ?? false
            let isWorking = session.status.isWorking

            switch (wasWorking, isWorking) {
            case (false, true):
                // 开工。first-seen 的会话也会走这里，但它可能已经跑了很久了，
                // 那种情况下算出来的时长偏短 —— 宁可偏短（判成低优、只上跑马灯），
                // 也不要凭空估一个大数把用户吵醒。
                workStartedAt[session.sessionId] =
                    session.statusUpdatedAt ?? session.updatedAt ?? Date()

            case (true, false):
                // 收工。
                guard let started = workStartedAt.removeValue(forKey: session.sessionId)
                else { break }
                let ended = session.statusUpdatedAt ?? session.updatedAt ?? Date()
                let duration = ended.timeIntervalSince(started)
                if duration > 0 { lastWorkDuration[session.sessionId] = duration }

            default:
                break
            }
        }

        // 会话没了就把它的记录清掉，别让字典无限涨。
        let alive = Set(fresh.map(\.sessionId))
        workStartedAt = workStartedAt.filter { alive.contains($0.key) }
        lastWorkDuration = lastWorkDuration.filter { alive.contains($0.key) }
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
        // 演示模式的会话不在任何终端里，真解析只会得到"未定位到终端"。
        if DemoFixtures.isEnabled {
            terminalLabels = DemoFixtures.terminalLabels()
            return
        }
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
        let probe = TmuxProbe()
        let panes = probe.bindPanes(to: pids, tree: tree)
        if !panes.isEmpty {
            // 问不出来时按"有连着"处理：标签只是显示，宁可少说一句
            // "终端已关"，也不要在探测抖动时给一堆正常会话贴错标。
            let attached = probe.attachedSessionNames() ?? Set(panes.values.map(\.sessionName))
            let sessionIdByPid = Dictionary(
                sessions.map { ($0.pid, $0.sessionId) }, uniquingKeysWith: { a, _ in a }
            )
            for (pid, pane) in panes {
                guard let sessionId = sessionIdByPid[pid] else { continue }
                // 没客户端连着的必须说出来。「tmux · hub:acme-erp」读起来像
                // 「去那个 tab 就能找到它」，可那个 tab 已经被关掉了 ——
                // 用户照着找会扑空，然后怀疑整个界面。
                let suffix = attached.contains(pane.sessionName) ? "" : "（终端已关，仍在后台跑）"
                let tmuxLabel = "tmux · \(pane.sessionName):\(pane.windowName)\(suffix)"
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
