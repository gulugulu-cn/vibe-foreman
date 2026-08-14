import Foundation
import HubCore
import HubJump
import HubProjects
import HubProbe

// 开发期 CLI：在 Xcode / UI 就绪之前，用它验证探测与跳转是否正确。
// 用法：
//   swift run hubprobe list          列出全部存活会话及其终端绑定
//   swift run hubprobe jump <n>      跳到第 n 个会话（list 里的序号）
//   swift run hubprobe jump <uuid>   跳到指定 sessionId

let reader = ClaudeSessionReader()
let tmux = TmuxProbe()
let iterm = ITermLocator()

func loadBindings() -> (
    sessions: [AgentSession],
    panes: [pid_t: TmuxPane],
    iterm: [String: String]
) {
    let sessions = reader.readAll().sorted {
        if $0.status != $1.status { return $0.status < $1.status }
        return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
    }
    let tree = ProcessTree.snapshot()
    let paneBinding = tmux.bindPanes(to: Set(sessions.map(\.pid)), tree: tree)
    let itermBinding = ITermLocator.isRunning()
        ? JumpEngine.bind(
            itermSessions: iterm.snapshot(),
            claudeSessions: sessions,
            tree: tree
        )
        : [:]
    return (sessions, paneBinding, itermBinding)
}

func pad(_ s: String, _ width: Int) -> String {
    // 中文按两个显示宽度算，否则表格会错位。
    let displayWidth = s.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2000 ? 2 : 1) }
    return s + String(repeating: " ", count: max(0, width - displayWidth))
}

func runList() {
    let (sessions, panes, itermMap) = loadBindings()
    guard !sessions.isEmpty else {
        print("没有存活的 Claude 会话。")
        return
    }

    print("共 \(sessions.count) 个存活会话\n")
    print(pad("#", 3) + pad("状态", 8) + pad("类型", 12) + pad("项目", 20)
        + pad("会话名", 34) + pad("tmux", 14) + "iTerm")
    print(String(repeating: "─", count: 104))

    for (i, s) in sessions.enumerated() {
        let kindLabel = s.kind == .bg ? "bg" : "interactive"
        let paneLabel = panes[s.pid].map { "\($0.windowId) \($0.windowName)" } ?? "—"
        let itermLabel = itermMap[s.sessionId] != nil ? "✓ 已绑定" : "✗ 未绑定"
        let statusLabel = s.status == .unknown ? "?\(s.rawStatus)" : s.status.rawValue

        print(pad("\(i)", 3)
            + pad(statusLabel, 8)
            + pad(kindLabel, 12)
            + pad(s.fallbackProjectName, 20)
            + pad(s.name ?? "—", 34)
            + pad(paneLabel, 14)
            + itermLabel)

        if let waitingFor = s.waitingFor {
            print("     ↳ 等待：\(waitingFor)")
        }
    }

    let unbound = sessions.filter { itermMap[$0.sessionId] == nil }
    if !unbound.isEmpty {
        print("\n未绑定到 iTerm 的会话（跳转会降级）：")
        for s in unbound {
            print("  - \(s.name ?? s.sessionId)  pid=\(s.pid)  cwd=\(s.cwd)")
        }
    }
}

func runJump(_ target: String) {
    let (sessions, _, _) = loadBindings()
    let sessionId: String

    if let index = Int(target) {
        guard index >= 0, index < sessions.count else {
            print("序号超出范围（0..<\(sessions.count)）")
            exit(1)
        }
        sessionId = sessions[index].sessionId
    } else {
        sessionId = target
    }

    guard let session = sessions.first(where: { $0.sessionId == sessionId }) else {
        print("找不到会话 \(sessionId)")
        exit(1)
    }

    print("跳转到：\(session.name ?? session.sessionId)  (\(session.fallbackProjectName))")
    switch JumpEngine().jump(to: sessionId) {
    case .focused(let strategy):
        print("✓ 成功，策略 \(strategy)")
    case .terminalActivatedOnly(let reason):
        print("△ 只前置了终端：\(reason)")
        exit(2)
    case .failed(let reason):
        print("✗ 失败：\(reason)")
        exit(1)
    }
}

/// 进度节流用的小计数器。
private final class Atomic: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func shouldReport(done: Int, total: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard done - value >= 50 || done == total else { return false }
        value = done
        return true
    }
}

/// 无头跑一遍用量统计。
///
/// 存在的理由：用量页藏在主窗口里，要点托盘图标才能打开，
/// 而验证它需要的恰恰是**耗时和数量**这类可量化的东西。
/// 有这个子命令就能直接 `time hubprobe usage` 看首扫和缓存命中的差别，
/// 不用去驱动 UI。
private func runUsage(_ rangeArgument: String?) {
    let range: UsageRange
    switch rangeArgument {
    case "7", "7d", "week", nil: range = .week7
    case "30", "30d", "month": range = .month30
    case "all", "全部": range = .all
    default:
        print("用法：hubprobe usage [7 | 30 | all]")
        exit(1)
    }

    let started = Date()
    // 进度回调可能从别的线程来，用一个原子计数器而不是捕获 var。
    let lastReported = Atomic()
    let summary = UsageStats.collect(range: range) { done, total in
        // 每 50 个报一次，别把输出刷爆。
        guard lastReported.shouldReport(done: done, total: total) else { return }
        FileHandle.standardError.write(Data("  扫描 \(done)/\(total)\n".utf8))
    }
    let elapsed = Date().timeIntervalSince(started)

    print("范围：\(range.rawValue)   耗时：\(String(format: "%.2f", elapsed)) 秒")
    print("会话 \(summary.totalSessions) · 消息 \(summary.totalMessages)")
    print("输入 \(summary.totalInput) · 输出 \(summary.totalOutput)")
    print("")
    for project in summary.projects.prefix(10) {
        print("  \(project.projectName.padding(toLength: 28, withPad: " ", startingAt: 0))"
            + " \(project.totalTokens)")
    }
}

/// 无头跑一遍滞留判定。
///
/// 存在的理由和 `usage` 一样：滞留提醒是**时间驱动**的，靠 UI 验证意味着
/// 干等三五分钟才知道判得对不对。这个子命令直接把当前每个会话的判定结果
/// 和判据（transcript 尾部、任务清单、静默时长）一次打出来，
/// 拿真实数据一眼就能看出规则是不是符合预期。
private func runStall(useAI: Bool) {
    let sessions = reader.readAll()
    guard !sessions.isEmpty else {
        print("没有存活的 Claude 会话。")
        return
    }

    let transcripts = TranscriptReader()
    let tasks = TaskStateReader()
    let detector = StallDetector()
    let judge = StallJudge()
    let now = Date()

    print("共 \(sessions.count) 个会话   （busyDuration 只有 app 在跑时才观测得到，这里一律未知）\n")

    for session in sessions.sorted(by: { $0.status < $1.status }) {
        let tail = transcripts.read(cwd: session.cwd, sessionId: session.sessionId)
        let snapshot = tasks.read(sessionId: session.sessionId)

        // 先不带 AI 判一次，判出来卡住了再决定要不要花额度问 AI ——
        // 生产里也是这个顺序，确定性规则优先，AI 只做兜底增强。
        let dry = StallDetector.Input(
            session: session, tail: tail, tasks: snapshot, busyDuration: nil, ai: nil
        )
        var ai: StallSummary?
        if useAI, detector.evaluate(dry, now: now) != nil,
           let text = tail?.lastAssistantText {
            ai = awaitSync { await judge.judge(sessionId: session.sessionId, assistantText: text) }
        }

        let input = StallDetector.Input(
            session: session, tail: tail, tasks: snapshot, busyDuration: nil, ai: ai
        )
        let finding = detector.evaluate(input, now: now)

        let silent = now.timeIntervalSince(
            session.statusUpdatedAt ?? session.updatedAt ?? now
        )
        print("\(pad(session.name ?? session.sessionId, 38))"
            + "\(pad(session.status.rawValue, 9))"
            + "静默 \(Int(silent / 60)) 分钟")

        let taskLabel = snapshot.map {
            $0.isEmpty ? "空" : "待办\($0.pending) 进行\($0.inProgress) 完成\($0.completed)"
        } ?? "无目录"
        print("   任务：\(taskLabel)"
            + "   尾部：\(tail == nil ? "读不到" : (tail!.endedWithApiError ? "API 错误" : "正常"))")

        if let finding {
            print("   → \(finding.reason.symbol) \(finding.reason.shortLabel)"
                + "  [\(finding.grade == .high ? "高优" : "低优")]  \(describe(finding.reason))")
        } else {
            print("   → 不提醒")
        }
        if let ai {
            print("   AI：\(ai.summary ?? "—")"
                + (ai.options.isEmpty ? "" : "   选项 \(ai.options.joined(separator: " / "))")
                + (ai.nextAction.map { "   下一步：\($0)" } ?? ""))
        }
        print("")
    }

    if useAI {
        let ledger = awaitSync { await judge.ledger }
        print("AI 调用 \(ledger.calls) 次（失败 \(ledger.failures)）"
            + "  花费 $\(String(format: "%.4f", ledger.costUSD))")
    }
}

/// 把 actor 上的异步调用桥回同步的 CLI 主流程。
///
/// 只在这个开发期 CLI 里用。app 里是真正的异步上下文，不需要也不该这么干。
private func awaitSync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task {
        result = await body()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

private func describe(_ reason: StallReason) -> String {
    switch reason {
    case .interrupted(let text): return StallDetector.condense(text, limit: 50)
    case .askedQuestion(let q): return q
    case .awaitingDecision(let why): return why ?? "—"
    case .unfinishedTasks(let p, let r, let next):
        return "待办\(p) 进行\(r)" + (next.map { "，下一件：\($0)" } ?? "")
    case .finishedAwaitingReview(let summary, _): return summary ?? "—"
    }
}

/// 走和 app 完全相同的那条派发路：ProjectStore → Project.expandedPath →
/// TerminalDispatch.open。
///
/// 加这个是为了把「界面把哪个项目传下来了」和「派发本身对不对」分开 ——
/// 实机上撞到过右键开出来的 claude 落在家目录，只看现象没法区分这两半，
/// 而没有 UI 的复现手段时只能靠读代码猜，猜了三轮没猜中。
@MainActor
func runLaunch(name: String, mode raw: String) {
    let store = ProjectStore()
    store.load()

    let needle = name.lowercased()
    guard let project = store.projects.first(where: {
        $0.name.lowercased() == needle
            || $0.aliases.contains { $0.lowercased() == needle }
    }) else {
        print("找不到项目：\(name)（共 \(store.projects.count) 个）")
        exit(1)
    }

    guard let mode = LaunchMode(rawValue: raw) else {
        print("未知 mode：\(raw)。可选：\(LaunchMode.allCases.map(\.rawValue).joined(separator: ", "))")
        exit(1)
    }

    print("项目 \(project.name)")
    print("  yaml 原文 path：\(project.path.isEmpty ? "<空>" : project.path)")
    print("  expandedPath ：\(project.expandedPath.isEmpty ? "<空>" : project.expandedPath)")
    print("  mode         ：\(mode.rawValue)")

    let ok = TerminalDispatch().open(
        project: project.name, path: project.expandedPath, mode: mode
    )
    print(ok ? "派发成功" : "派发失败（详见 launch.log）")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "list", nil:
    runList()
case "stall":
    runStall(useAI: args.contains("--ai"))
case "jump":
    guard args.count >= 2 else {
        print("用法：hubprobe jump <序号或 sessionId>")
        exit(1)
    }
    runJump(args[1])
case "usage":
    runUsage(args.count >= 2 ? args[1] : nil)
case "launch":
    guard args.count >= 2 else {
        print("用法：hubprobe launch <项目名> [claude|terminal|finder|vscode|resumeLast]")
        exit(1)
    }
    runLaunch(name: args[1], mode: args.count >= 3 ? args[2] : "finder")
default:
    print("""
    用法：hubprobe [list | jump <序号或 sessionId> | usage [7|30|all] \
    | stall [--ai] | launch <项目名> [mode]]
    """)
    exit(1)
}
