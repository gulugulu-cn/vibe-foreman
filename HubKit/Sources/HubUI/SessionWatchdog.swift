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
    @ObservationIgnored private let acceptance: AcceptanceStore
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
    /// 上一轮抓到的画面。**画面变了就说明它在动**，哪怕状态是 shell、
    /// 哪怕转圈行被滚屏顶掉了。慢命令的输出在往外吐时画面一直在变，
    /// 这是比"有没有转圈符号"可靠得多的判据。
    @ObservationIgnored private var lastPane: [String: String] = [:]

    public init(
        store: SessionStore,
        projects: ProjectStore,
        acceptance: AcceptanceStore,
        url: URL? = SessionWatchdog.defaultURL
    ) {
        self.store = store
        self.projects = projects
        self.acceptance = acceptance
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

    /// 手写的通用追问。界面上可编辑的就是这一份。
    public func probeList(for projectPath: String) -> [String] {
        let custom = probes[projectPath] ?? []
        return custom.isEmpty ? Self.defaultProbes : custom
    }

    /// 从验收清单**当场生成**的追问。
    ///
    /// ## 为什么不能只靠手写清单
    ///
    /// 手写的那些是通用问题（"落到哪些文件了"、"有哪些卡点"）。问几轮之后
    /// 它就摸清套路了，答案会越来越像模板。而清单里明明躺着 18 条待验收、
    /// 7 条存疑 —— **那些才是该问的具体问题**，而且每一条都问不出模板答案。
    ///
    /// 存疑的排最前：那一档是「它自报做完了、但真实 diff 里找不到」，
    /// 是整个清单里最该当面对质的。
    public func generatedProbes(for projectPath: String) -> [String] {
        let items = acceptance.ledger(for: projectPath).items
            .filter { $0.needsAttention && !$0.likelyMisextracted }
            .sorted { left, _ in left.status == .disputed }

        return items.prefix(12).map { item in
            let text = item.text.count <= 46 ? item.text : String(item.text.prefix(45)) + "…"
            if item.status == .disputed {
                let why = item.note.map { "（复核说：\($0)）" } ?? ""
                return "你说做完了「\(text)」，但真实 diff 里找不到对应改动\(why)。具体是哪个文件的哪几行实现的？找不到就直说没做。"
            }
            let how = item.acceptance.map { "验收条件是：\($0)。" } ?? ""
            return "「\(text)」这条做了吗？\(how)做了给文件路径和行号，没做直接说没做，别绕。"
        }
    }

    /// 真正发出去的那一条。**通用和清单生成交替** ——
    /// 只问清单会让人一直在对答案，只问通用又摸不到具体的漏项。
    func nextProbe(for projectPath: String) -> String? {
        let generic = probeList(for: projectPath)
        let generated = generatedProbes(for: projectPath)
        let index = probeIndex[projectPath] ?? 0

        // 偶数轮问通用、奇数轮问清单里的具体条目；某一边空了就全走另一边。
        let useGenerated = index % 2 == 1
        let pool = useGenerated
            ? (generated.isEmpty ? generic : generated)
            : (generic.isEmpty ? generated : generic)
        guard !pool.isEmpty else { return nil }
        return pool[(index / 2) % pool.count]
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

        var matched = 0
        // **每个会话都要记一句。** 只留最后一个的结果时，一个残留的死会话
        // 会把真正在跑的那个整个盖掉 —— 实测第一条心跳就撞上了：
        // 显示"找不到 53603 对应的 pane"，而 44669 的情况完全看不见。
        var notes: [String] = []
        for session in store.sessions {
            let path = AcceptanceStore.projectPath(forCWD: session.cwd, projects: projects)
            guard watching.contains(path) else { continue }
            matched += 1
            let name = session.name ?? String(session.sessionId.prefix(8))
            notes.append("[\(name)] \(evaluate(session, projectPath: path))")
        }
        let note = matched == 0
            ? "没有会话落在被盯的项目里（共 \(store.sessions.count) 个会话）"
            : notes.joined(separator: " · ")

        // 心跳。**没有它，"盯梢没在工作"和"盯梢工作了但没到该催的时候"
        // 在外面看起来一模一样** —— 都是没有任何输出。
        // 我就是因为分不清这两种，让一个死掉的盯梢挂了快 4 小时。
        //
        // 写文件而不是打日志：本机实测 `log show` 完全看不到这个 app 的输出
        // （连启动那条都没有，多半和 ad-hoc 签名有关）。
        // **一个看不见的仪表比没有仪表更糟** —— 我拿它做过诊断，得出了错误结论。
        lastTick = Date()
        lastTickDetail = "\(watching.count) 个项目在盯，本轮命中 \(matched) 个会话；\(note)"
        persist()
    }

    /// 上一次检查的时刻和结果。界面上直接显示 —— 用户要能自己判断它到底活着没有。
    public private(set) var lastTick: Date?
    public private(set) var lastTickDetail: String = "还没跑过"

    /// 拿到 tmux 里真正的 pane 目标（`%15` 这种）。
    ///
    /// pane 的 `pane_pid` 是它直接起的那个进程 —— 可能是 shell，claude 是它的
    /// 后代。所以从 claude 的 pid 一路往上找父进程，直到撞上某个 pane_pid。
    static func paneTarget(pid: pid_t) -> String? {
        guard let tmux = tmuxPath else { return nil }
        let listing = Shell.run(
            tmux, ["list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"], timeout: 5
        ).stdout
        guard !listing.isEmpty else { return nil }

        var panes: [pid_t: String] = [:]
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let panePid = pid_t(parts[1]) else { continue }
            panes[panePid] = String(parts[0])
        }

        var current = pid
        // 往上走几层就够了（claude → shell → pane）。加上界防止父子环。
        for _ in 0..<8 {
            if let pane = panes[current] { return pane }
            guard let parent = Self.parent(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        let out = Shell.run("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"], timeout: 3).stdout
        return pid_t(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    private func evaluate(_ session: AgentSession, projectPath: String) -> String {
        // ⚠️ 不能用 `TerminalReply.locate()` —— 它返回的是给人看的**标签**
        //（"tmux · hub:agentx-dev-kit"），不是 tmux 的 pane 目标。
        // 拿它去 `capture-pane -t` 必然失败，而失败是静默的：
        // 抓到空字符串 → 判成"没在干活"或者干脆什么都不做。
        // 实机上盯梢因此整整 83 分钟一次都没催 —— 用户先发现的，不是程序。
        guard let pane = Self.paneTarget(pid: session.pid) else {
            // 不在 tmux 里 —— VS Code 扩展、直接开的终端都是这样。
            // **这不是故障**：盯梢靠 tmux 注入，够不着的会话跳过就是了。
            // 早先这里写的是"找不到 pane"，读起来像出错，
            // 于是外面的监听把一个完全正常的情况报成了告警。
            streak[session.sessionId] = 0
            return "不在 tmux 里，跳过"
        }

        let text = Self.capture(pane: pane)
        // 抓不到画面时**不做判断**。空字符串会让 isWorking / draft 全部返回
        // "没有"，于是看起来像"停着可以催" —— 那是拿抓取失败当成了结论。
        guard !text.isEmpty else {
            streak[session.sessionId] = 0
            return "抓不到 \(pane) 的画面"
        }
        if let reason = PaneActivity.doNotDisturb(status: session.rawStatus, pane: text) {
            lastPane[session.sessionId] = text
            streak[session.sessionId] = 0
            return "不打扰：\(reason)"
        }

        // 画面和上一轮不一样 = 有东西在往外吐 = 它在干活。
        //
        // 这条是为「跑得慢的 shell 命令」加的：那种场景下状态可能是 shell、
        // 转圈行可能被滚屏顶掉，但输出一直在变。只看转圈符号会把它误判成停了，
        // 然后在它跑到一半时插一句话 —— 用户明确提过要避免这种混乱。
        let previous = lastPane[session.sessionId]
        lastPane[session.sessionId] = text
        if let previous, previous != text {
            streak[session.sessionId] = 0
            return "不打扰：画面还在变（多半是命令在跑）"
        }

        let count = (streak[session.sessionId] ?? 0) + 1
        streak[session.sessionId] = count
        guard count >= needStreak else { return "停着，第 \(count)/\(needStreak) 次确认" }

        let now = Date()
        if let last = lastNudgeAt[session.sessionId], now.timeIntervalSince(last) < cooldown {
            return "停着但在冷却期内"
        }

        // **先看它刚说了什么。** 它在问一个等你拍板的问题时，照常甩出轮到的
        // 那条追问会把问题直接埋掉 —— 它在等的决定没人回，用户看到的是
        // 一句驴唇不对马嘴的话。实机上就这么发生过。
        //
        // 这时候不发清单里的问题，而是回应它：把决定权交回去让它自己走，
        // 并且**把原问题原样带上**，让用户在历史里一眼看到它问过什么。
        let probe: String
        if let question = PaneActivity.pendingQuestion(pane: text) {
            // 光说"自己看着办"是把球踢回去，它下一轮很可能又来问一次。
            // **顺带派一件具体的活**：从清单里挑一条还没做的，让它有明确的下一步。
            let next = generatedProbes(for: projectPath).first
            let assignment = next.map { "顺带下一件事：\($0.prefix(60))" }
                ?? "然后接着把手上的活往下推。"
            probe = "你在问：「\(question.prefix(40))」——自己判断着办，不用等我拍板。\(assignment)"
        } else {
            guard let next = nextProbe(for: projectPath) else { return "追问清单是空的" }
            probe = next
            let index = probeIndex[projectPath] ?? 0
            probeIndex[projectPath] = index + 1
        }

        streak[session.sessionId] = 0
        lastNudgeAt[session.sessionId] = now
        let name = session.name ?? String(session.sessionId.prefix(8))
        history.insert(NudgeRecord(at: now, sessionName: name, probe: probe), at: 0)
        // 只留最近这些。历史是给人看"它到底说过什么"的，不是审计日志。
        if history.count > 50 { history.removeLast(history.count - 50) }
        // **必须落盘。** 不落的话界面上和文件里都看不到它说过话 ——
        // 而"它到底催没催"正是排障时唯一想知道的事。
        // 我自己就因为读了这个没更新的文件，误判成"一次都没催"。
        persist()

        let outcome = Self.inject(probe, into: pane)
        return "追问 \(name)：\(probe.prefix(24))… —— \(outcome)"
    }

    /// 把追问敲进终端。
    ///
    /// ## 为什么不用 `TerminalReply.send`
    ///
    /// 它里面有 `guard !session.status.isWorking`，而 `isWorking` 包含 `shell`。
    /// 那个判断对它本来的用途（答终端弹出的权限对话框）是对的 —— 会话在忙时
    /// 往输入框敲字会串进别的地方。
    ///
    /// 但对盯梢来说 **`shell` 恰恰是最该催的状态**（挂着后台 shell、人却停在
    /// 提示符上）。用它的话每次都会被静默挡掉，返回 `.sessionBecameBusy`，
    /// 而我原来把返回值扔了（`_ = await ...`），于是历史里记着"追问了"、
    /// 终端里一个字都没有。实机撞到过。
    ///
    /// ## 分两步发
    ///
    /// 先文字、停一下、再回车。合在一起时终端偶尔会把回车吃进上一段输入里，
    /// 消息卡在输入框发不出去 —— 看起来催过了，其实一个字没送。
    static func inject(_ text: String, into pane: String) -> String {
        guard let tmux = tmuxPath else { return "找不到 tmux" }
        // 换行会被当成"再敲一次回车"，凭空多发一条输入；控制字符能改终端模式。
        // 追问清单是用户自己编辑的，这两条必须挡住。
        guard !text.contains(where: \.isNewline),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return "追问里有换行或控制字符，拒发" }

        let typed = Shell.run(tmux, ["send-keys", "-t", pane, "-l", text], timeout: 5)
        guard typed.succeeded else { return "敲字失败：\(typed.stderr)" }
        Thread.sleep(forTimeInterval: 0.5)
        let entered = Shell.run(tmux, ["send-keys", "-t", pane, "Enter"], timeout: 5)
        guard entered.succeeded else { return "回车失败：\(entered.stderr)" }
        return "已送达"
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
        var lastTick: Date?
        var lastTickDetail: String?
    }

    private func load() {
        guard let url,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        watching = Set(payload.watching)
        probes = payload.probes
        history = payload.history
        lastTick = payload.lastTick
        lastTickDetail = payload.lastTickDetail ?? "还没跑过"
    }

    private func persist() {
        guard let url else { return }
        let payload = Payload(
            watching: watching.sorted(), probes: probes, history: Array(history.prefix(50)),
            lastTick: lastTick, lastTickDetail: lastTickDetail
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
