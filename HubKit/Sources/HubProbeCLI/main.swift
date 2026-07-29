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

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "list", nil:
    runList()
case "jump":
    guard args.count >= 2 else {
        print("用法：hubprobe jump <序号或 sessionId>")
        exit(1)
    }
    runJump(args[1])
case "usage":
    runUsage(args.count >= 2 ? args[1] : nil)
default:
    print("用法：hubprobe [list | jump <序号或 sessionId> | usage [7|30|all]]")
    exit(1)
}
