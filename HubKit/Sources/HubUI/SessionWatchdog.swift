import Foundation
import HubCore
import HubProbe
import HubProjects
import Observation

/// 一次追问的记录。UI 上要看得见 —— 一个"在盯着"但从没说过话的盯梢，
/// 和没开是一样的，而用户没法区分这两种。
public struct NudgeRecord: Codable, Sendable, Equatable {
    public let at: Date
    public let sessionName: String
    public let probe: String

    public init(at: Date, sessionName: String, probe: String) {
        self.at = at
        self.sessionName = sessionName
        self.probe = probe
    }
}

/// 会话观察者：盯着指定项目的会话，停下来就追问，直到活真的干透。
///
/// ## 它解决的不是「停了」，是「做浅了」
///
/// 只会说「继续」的盯梢能防它停，防不了它每次都继续、每次都做表面功夫，
/// 最后交一份看起来很完整的报告。所以追问是一份**轮换的清单**：
/// 落到哪些文件了、发布后还在不在、测了几轮、调过什么参数、
/// 哪些卡点没解决 —— 每次问一条，问完从头再来。
///
/// ## 三条硬约束（都是实机撞出来的）
///
/// 1. **只有 `busy` 算在干活。** `shell` 表示"挂着后台 shell"，和 Claude
///    在不在思考无关 —— 早期版本把它当成在干活，会话停了 20 分钟一次没催到。
/// 2. **用户在输入框里打字时绝不发。** 注入是往当前光标位置敲字，
///    会直接拼到他没发完的那句后面，改变他本来要说的意思。
/// 3. **发送分两步**（先文字、停一下、再回车）。合在一起时终端偶尔会把回车
///    吃进上一段输入里，消息卡在输入框发不出去 —— 看起来催过了，其实一个字没送。
///
/// 前两条的判断在 `PaneActivity` 里，是纯函数，有测试钉着。
@Observable
@MainActor
public final class SessionWatchdog {

    /// 正在盯的项目路径。
    public private(set) var watching: Set<String> = []
    /// 每个项目的追问清单。空 = 用默认那份。
    public private(set) var probes: [String: [String]] = [:]
    /// 最近的追问记录，最新的在前。
    public private(set) var history: [NudgeRecord] = []

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let projects: ProjectStore
    @ObservationIgnored private let reply = TerminalReply()
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var timer: Timer?

    /// 连续几次判定"停着"才真的开口。一次就发的话，两次工具调用之间的
    /// 那点空档也会被当成停了。
    private let needStreak = 2
    /// 两次追问的最小间隔。它读完一条要想一会儿，催太密就是打断。
    private let cooldown: TimeInterval = 180
    private let interval: TimeInterval = 45

    @ObservationIgnored private var streak: [String: Int] = [:]
    @ObservationIgnored private var lastNudgeAt: [String: Date] = [:]
    @ObservationIgnored private var probeIndex: [String: Int] = [:]

    public init(
        store: SessionStore,
        projects: ProjectStore,
        url: URL? = SessionWatchdog.defaultURL
    ) {
        self.store = store
        self.projects = projects
        self.url = url
        load()
    }

    public nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/watchdog.json")
    }

    // MARK: - 开关

    public func isWatching(_ projectPath: String) -> Bool { watching.contains(projectPath) }

    public func setWatching(_ on: Bool, _ projectPath: String) {
        if on { watching.insert(projectPath) } else { watching.remove(projectPath) }
        persist()
    }

    public func probeList(for projectPath: String) -> [String] {
        let custom = probes[projectPath] ?? []
        return custom.isEmpty ? Self.defaultProbes : custom
    }

    public func setProbes(_ list: [String], for projectPath: String) {
        probes[projectPath] = list.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        persist()
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
        guard !watching.isEmpty else { return }

        for session in store.sessions {
            let path = AcceptanceStore.projectPath(forCWD: session.cwd, projects: projects)
            guard watching.contains(path) else { continue }
            evaluate(session, projectPath: path)
        }
    }

    private func evaluate(_ session: AgentSession, projectPath: String) {
        guard let pane = reply.locate(sessionId: session.sessionId, session: session) else {
            // 找不到终端就别猜。往一个定位不到的窗口敲字比不敲危险。
            streak[session.sessionId] = 0
            return
        }

        let text = Self.capture(pane: pane)
        if let reason = PaneActivity.doNotDisturb(status: session.rawStatus, pane: text) {
            if (streak[session.sessionId] ?? 0) > 0 {
                HubLog.app.notice("盯梢：\(session.sessionId.prefix(8), privacy: .public) 又动了（\(reason, privacy: .public)）")
            }
            streak[session.sessionId] = 0
            return
        }

        let count = (streak[session.sessionId] ?? 0) + 1
        streak[session.sessionId] = count
        guard count >= needStreak else { return }

        let now = Date()
        if let last = lastNudgeAt[session.sessionId], now.timeIntervalSince(last) < cooldown {
            return
        }

        let list = probeList(for: projectPath)
        guard !list.isEmpty else { return }
        let index = (probeIndex[projectPath] ?? 0) % list.count
        let probe = list[index]
        probeIndex[projectPath] = (index + 1) % list.count

        streak[session.sessionId] = 0
        lastNudgeAt[session.sessionId] = now
        let name = session.name ?? String(session.sessionId.prefix(8))
        history.insert(NudgeRecord(at: now, sessionName: name, probe: probe), at: 0)
        // 只留最近这些。历史是给人看"它到底说过什么"的，不是审计日志。
        if history.count > 50 { history.removeLast(history.count - 50) }

        Task { [reply] in
            _ = await reply.send(text: probe, to: session.sessionId)
        }
        HubLog.app.notice("""
        盯梢：向 \(name, privacy: .public) 追问第 \(index + 1, privacy: .public)/\
        \(list.count, privacy: .public) 条
        """)
    }

    /// 抓终端画面。只要最后 14 行 —— 转圈行和输入框都在底部，
    /// 抓多了只是把历史消息里的 `❯` 一起带进来，反而增加误判。
    static func capture(pane: String) -> String {
        guard let tmux = tmuxPath else { return "" }
        return Shell.run(
            tmux, ["capture-pane", "-t", pane, "-p", "-S", "-14"], timeout: 5
        ).stdout
    }

    /// 找 tmux。**不能靠 PATH** —— Hub 是 GUI app，从 launchd 起，
    /// PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，homebrew 装的 tmux 不在里面。
    /// 同 `StallJudge.locateClaude` 的理由。
    private static let tmuxPath: String? = [
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    // MARK: - 默认追问清单

    /// 通用版。项目可以在设置里换成自己的。
    ///
    /// 每一条都是一个**它不想被问的角度** —— 这就是观察者的全部价值。
    /// 「继续」只在第一条，因为防停是最低要求，不是目的。
    public static let defaultProbes: [String] = [
        "继续，不要停。把手上的活干完再停，遇到卡点自己想办法绕过去。",
        "这轮的产出具体落到了哪些文件？给完整路径。答不上路径就说明只写了结论没落地。",
        "你落的那些改动，下一次构建/发布之后还在不在？不确定就去看构建脚本，别猜。",
        "现在有哪些卡点还没解决、哪些落点还没落？别报喜不报忧——只说做成的部分等于把问题留给我。",
        "你自己列的 todo 逐条对一遍：哪些真做完了、哪些只是勾了框？勾了但没动代码的直接说。",
        "回头把需求原文再看一遍。你的上下文可能被压缩过，对照文档确认，不要凭记忆。",
        "如果现在把这些改动交给真实用户用，最可能在哪一步翻车？说实话。",
        "同一件事你重复从头做了几次？可以复用的部分固化下来，每轮只跑增量——每次都重头来是在烧时间。",
    ]

    // MARK: - 持久化

    private struct Payload: Codable {
        var watching: [String]
        var probes: [String: [String]]
        var history: [NudgeRecord]
    }

    private func load() {
        guard let url,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        watching = Set(payload.watching)
        probes = payload.probes
        history = payload.history
    }

    private func persist() {
        guard let url else { return }
        let payload = Payload(
            watching: watching.sorted(), probes: probes, history: Array(history.prefix(50))
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
