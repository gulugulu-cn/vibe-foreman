import Foundation
import HubCore
import HubProbe
import Observation

/// 关掉终端窗口就结束会话。
///
/// ## 它在补什么
///
/// tmux 的默认语义是「关窗口 = detach，进程照跑」。这对跑长活是对的，
/// 但和用户的心智模型相反：他关掉窗口就是干完了，之后在界面上看到
/// 「1 个会话」亮着，只会认为界面在撒谎。用户明确选了这一侧：关窗即结束。
///
/// ## 三条必须守住的边界
///
/// 1. **杀之前先把 sessionId 记进名册**（`ClosedSessionStore`）。
///    用户的原话是「那我也打不开了呀」—— 只会杀不会还的回收器是把一个
///    显示错误的会话换成一个找不回来的会话。transcript 在磁盘上好好的，
///    丢的只是那个 id，不记就真的没了。
///
/// 2. **绑不到 tmux pane 的一律不碰。** 那是根本不在 tmux 里的会话
///    （VS Code 扩展、直接开的终端、bg 任务），"有没有终端连着"这件事
///    对它们无从判断，杀它们等于拿"不知道"当处决理由。
///
/// 3. **新起的会话有宽限期。** `TerminalDispatch.createSession` 是先建
///    detached 的 tmux 会话、再让终端去 attach 的；iTerm 冷启动那几秒里
///    客户端数就是 0。没有宽限期的话，回收器会把用户刚点开的项目当场杀掉 ——
///    表现是"点了没反应"，而且查不出原因。
@Observable
@MainActor
public final class SessionReaper {

    /// 总开关。**必须能关** —— 这是全案第二个会主动杀进程的组件，
    /// 一个杀错了没法阻止的自动行为不该存在。
    public var enabled: Bool = true {
        didSet {
            guard enabled != oldValue else { return }
            if !enabled { strikes.removeAll() }
            persist()
        }
    }

    /// 最近一次回收了什么。界面上要看得见 —— 一个默默杀进程的东西，
    /// 用户下次发现会话没了会以为是崩了。
    public private(set) var lastReaped: [ClosedSession] = []

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let closed: ClosedSessionStore
    /// 用来回答「这个会话接得回来吗」。见 `apply` 里那段说明。
    @ObservationIgnored private let transcripts = TranscriptReader()
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var timer: Timer?

    /// sessionId → 连续几轮观察到"没客户端连着"。
    @ObservationIgnored private var strikes: [String: Int] = [:]

    /// 连续几轮才动手。一轮就杀的话，用户 detach 一下再连回来
    ///（换窗口、iTerm 重启恢复会话）都会被当成关掉了。
    private let needStrikes = 2
    private let interval: TimeInterval = 15

    /// 会话起来多久之内不碰。覆盖 iTerm 冷启动 + attach 的全过程，
    /// 见类型注释第 3 条。
    private let launchGrace: TimeInterval = 90

    public nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/reaper.json")
    }

    public init(
        store: SessionStore,
        closed: ClosedSessionStore,
        url: URL? = SessionReaper.defaultURL
    ) {
        self.store = store
        self.closed = closed
        self.url = url
        load()
    }

    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 每一轮

    func tick() {
        guard enabled, !DemoFixtures.isEnabled else { return }
        let snapshot = store.sessions
        guard !snapshot.isEmpty else {
            strikes.removeAll()
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            let probe = TmuxProbe()
            let pairs = DetachedSessions.pairs(
                sessions: snapshot,
                panes: probe.listPanes(),
                attached: probe.attachedSessionNames(),
                tree: ProcessTree.snapshot()
            )
            await MainActor.run { self?.apply(pairs, now: Date()) }
        }
    }

    /// 记账 + 动手。纯粹的判断在 `shouldReap`，这里只负责计数和执行。
    private func apply(_ pairs: [(session: AgentSession, pane: TmuxPane)], now: Date) {
        let detached = Dictionary(
            pairs.map { ($0.session.sessionId, $0) }, uniquingKeysWith: { a, _ in a }
        )

        // 连回来的、或者已经不在了的，计数清零。**必须清** ——
        // 不清的话「detach 一下再连回来」几次就会攒够次数，
        // 然后在一个连着终端的会话上动手。
        strikes = strikes.filter { detached[$0.key] != nil }

        var reaped: [ClosedSession] = []
        for (sessionId, pair) in detached {
            guard Self.isOldEnough(pair.session, now: now, grace: launchGrace) else {
                // 宽限期内不计数：计到一半等宽限期一过就立刻够数，
                // 等于宽限期形同虚设。
                strikes[sessionId] = 0
                continue
            }

            let count = (strikes[sessionId] ?? 0) + 1
            strikes[sessionId] = count
            guard count >= needStrikes else { continue }

            // **只有存下了 transcript 的才进名册。**
            //
            // 「接着上次」靠的是 `claude --resume <id>`，而它认的是磁盘上那份
            // transcript，不是这个 id 本身。一次都没说过话的会话压根没有
            // transcript 文件（实机验证过：一个 11:35 起来、只停在提示符上的
            // 会话，`~/.claude/projects/…` 里一个字节都没有）。
            // 不查就记的话，项目行上会出现一个「接着上次」按钮，点下去
            // claude 报错退出 —— 比没有这个按钮更糟。
            let resumable = Self.isResumable(
                cwd: pair.session.cwd, sessionId: sessionId, reader: transcripts
            )
            let record = ClosedSession(
                sessionId: sessionId,
                name: pair.session.name ?? String(sessionId.prefix(8)),
                cwd: pair.session.cwd,
                endedAt: now
            )
            // **先记名册，再杀。** 顺序反过来的话，杀完崩了就再也接不回来。
            if resumable { closed.record(record) }
            guard Self.kill(pane: pair.pane) else {
                // 杀失败就把名册那条撤掉 —— 进程还活着却在"已结束"列表里，
                // 用户点「接着上次」会开出第二个同 id 的会话。
                if resumable { closed.forget(sessionId: sessionId) }
                continue
            }
            strikes[sessionId] = nil
            if resumable { reaped.append(record) }
            HubLog.app.notice("""
            终端已关，结束会话 \(record.name, privacy: .public)\
            （\(sessionId, privacy: .public)，\
            \(resumable ? "可接回" : "无 transcript，不入名册", privacy: .public)）
            """)
        }

        if !reaped.isEmpty { lastReaped = reaped }
    }

    /// 这个会话接得回来吗。
    ///
    /// 判据是**磁盘上那份 transcript 在不在**，不是"有没有 sessionId"。
    /// `claude --resume <id>` 认的是文件；一次都没说过话的会话没有文件，
    /// 那个 id 给出去只会换来一次报错退出。
    static func isResumable(cwd: String, sessionId: String, reader: TranscriptReader) -> Bool {
        reader.locate(cwd: cwd, sessionId: sessionId) != nil
    }

    /// 起来够久了吗。`startedAt` 缺失时**当成够久** ——
    /// 缺字段的会话通常是早就在跑的老会话，把它无限期豁免反而会让
    /// 回收器对最该收的那批永远不动手。
    static func isOldEnough(_ session: AgentSession, now: Date, grace: TimeInterval) -> Bool {
        guard let started = session.startedAt else { return true }
        return now.timeIntervalSince(started) >= grace
    }

    /// 杀 pane，不是杀 window。
    ///
    /// pane 是最小的、确定属于这个会话的单位。用 `kill-window` 的话，
    /// 用户要是在同一个窗口里分屏跑了别的东西（构建、日志），会被一起带走。
    /// pane 是窗口里最后一个时 tmux 自己会把窗口收掉，常见情形下效果一样。
    static func kill(pane: TmuxPane) -> Bool {
        guard let tmux = tmuxPath else { return false }
        return Shell.run(tmux, ["kill-pane", "-t", pane.paneId], timeout: 5).succeeded
    }

    /// 同 `SessionWatchdog.tmuxPath`：GUI app 的 PATH 里没有 homebrew。
    private static let tmuxPath: String? = [
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    // MARK: - 持久化

    private struct Payload: Codable { var enabled: Bool }

    private func load() {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        // 绕开 didSet：加载不是"用户改了设置"。
        _enabled = decoded.enabled
    }

    private func persist() {
        guard let url, let data = try? JSONEncoder().encode(Payload(enabled: enabled)) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
