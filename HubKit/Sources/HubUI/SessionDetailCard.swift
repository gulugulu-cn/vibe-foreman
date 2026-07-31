import AppKit
import HubCore
import HubJump
import HubProbe
import HubProjects
import SwiftUI

/// 用哪个编辑器打开会话目录。
///
/// 按用户实际会用的顺序探测，**只在 app 真的装了的时候才显示按钮** ——
/// 点了没反应比没有这个按钮更糟。
enum EditorLauncher {
    struct Editor {
        let name: String
        let bundleId: String

        func open(_ path: String) {
            guard let app = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleId) else { return }
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: path)],
                withApplicationAt: app,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    private static let candidates: [Editor] = [
        Editor(name: "Cursor", bundleId: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "VS Code", bundleId: "com.microsoft.VSCode"),
        Editor(name: "Zed", bundleId: "dev.zed.Zed"),
        Editor(name: "Xcode", bundleId: "com.apple.dt.Xcode"),
    ]

    /// 首个已安装的编辑器。查一次就缓存 —— `urlForApplication` 会打 LaunchServices。
    static let preferred: Editor? = candidates.first {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil
    }
}

/// 展开态顶部的会话详情卡。
///
/// 这是「点击小人显示具体信息以及运作状态」的落点：把一个会话**当下**的全部
/// 可知事实摊开 —— 它是谁、在哪个目录、哪条分支、最近提交了什么、干了多久、
/// 人在哪个终端能找到它。
///
/// 目录和分支不是装饰：**同一个项目经常多开**（几个会话跑在不同 worktree 或
/// 不同分支上），只显示项目名的话它们看起来一模一样，根本分不清点哪个。
///
/// 数据全部来自已经采集好的缓存，卡片本身不发起任何子进程调用，
/// 所以切换选中不会有任何卡顿。
struct SessionDetailCard: View {
    let session: AgentSession
    var workspace: WorkspaceGit?
    var terminalLabel: String?
    var jumpOutcome: JumpOutcome?
    /// 这个会话卡住了吗、为什么。
    ///
    /// 之前滞留信息只活在 `.nudge` 形态和折叠态的跑马灯里 —— 用户一展开列表
    /// （也就是他真正要动手的地方）它就消失了，反而在最该看到的位置看不到。
    var stall: StallFinding?
    let onJump: () -> Void
    /// 进应答态直接回答。只有 `askedQuestion` 才给这个入口。
    var onAnswer: (() -> Void)?

    private var accent: Color { IslandTheme.color(for: session.status) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            portrait

            VStack(alignment: .leading, spacing: 5) {
                titleRow
                locationRow
                factsRow
                Spacer(minLength: 2)
                // 卡住时用滞留横幅**顶掉**提交记录。
                // 两者都要位置，而"这件事在等你"永远比"三天前提交了什么"更急。
                if stall != nil {
                    stallBanner
                } else {
                    commitLog
                }
            }

            Spacer(minLength: 4)

            actions
        }
        .padding(12)
        .frame(height: IslandMetrics.expandedDetailHeight)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(accent.opacity(session.status == .idle ? 0.18 : 0.34), lineWidth: 1)
                }
        }
    }

    // MARK: 滞留横幅

    /// 卡住的原因 + 能做什么。
    ///
    /// 三段式：图标、原因短语、具体内容。短语（"在问你"）负责扫一眼就懂，
    /// 具体内容（问题原文 / 下一件任务 / 错误摘要）负责不用跳过去就知道是什么事。
    @ViewBuilder
    private var stallBanner: some View {
        if let stall {
            let tone = StallPalette.color(for: stall.reason)
            HStack(alignment: .top, spacing: 7) {
                Text(stall.reason.symbol)
                    .font(.system(size: 11))

                VStack(alignment: .leading, spacing: 2) {
                    Text(stall.reason.shortLabel)
                        .font(IslandTheme.label(11, .bold))
                        .foregroundStyle(tone)
                    Text(stallDetail(stall.reason))
                        .font(IslandTheme.label(10.5, .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                // 只有"在问你"给这个入口 —— 断线、待验收没有一句话就能回应的动作，
                // 硬做成按钮是假的。
                if case .askedQuestion = stall.reason, let onAnswer {
                    Button {
                        onAnswer()
                    } label: {
                        Text("回答").padding(.horizontal, 8)
                    }
                    .buttonStyle(IslandButtonStyle(
                        emphasis: .prominent, tint: tone, height: 22
                    ))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tone.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(tone.opacity(0.30), lineWidth: 1)
                    }
            }
        }
    }

    private func stallDetail(_ reason: StallReason) -> String {
        switch reason {
        case .interrupted(let text):
            return StallDetector.condense(text, limit: 70)
        case .askedQuestion(let question):
            return question
        case .awaitingDecision(let why):
            return why ?? "在等你授权或选择"
        case .unfinishedTasks(let pending, let running, let next):
            let head = next.map { "下一件：\($0)" } ?? "还有没做完的"
            return "\(head)（待办 \(pending) · 进行中 \(running)）"
        case .finishedAwaitingReview(let summary, let worked):
            let time = worked >= 60 ? "干了 \(Int(worked / 60)) 分钟，" : ""
            return time + (summary ?? "完成了一轮，等你验收")
        }
    }

    // MARK: 大号小人

    /// 详情卡用 3pt/px（48pt）而不是把 32pt 的放大 —— `pixelSize` 必须是整数，
    /// 非整数会产生半像素，边缘发灰，像素风立刻变成"低分辨率图片"。
    private var portrait: some View {
        VStack(spacing: 6) {
            SpriteScreen(cornerRadius: 10) {
                PixelSprite(session: session, pixelSize: 3, gridSize: 16)
            }
            Text(session.kind == .bg ? "后台" : "交互")
                .font(IslandTheme.label(9, .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: 标题

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(session.name ?? session.sessionId)
                .font(IslandTheme.label(14, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            StatusDot(status: session.status, size: 6)
            Text(statusText)
                .font(IslandTheme.label(10, .semibold))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(accent.opacity(0.14), in: .capsule)
    }

    private var statusText: String {
        switch session.status {
        case .busy: return "工作中"
        case .waiting: return session.waitingFor ?? "等你输入"
        case .shell: return "跑命令"
        case .idle: return "空闲"
        case .unknown: return session.rawStatus
        }
    }

    // MARK: 位置：目录 + 分支

    /// 当前目录和分支放同一行，因为它们回答的是同一个问题：
    /// **这个会话到底在哪个工作区上干活。** 一个项目多开时这是唯一的区分手段。
    private var locationRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 8))
                Text(displayPath)
                    .font(IslandTheme.mono(10))
                    .lineLimit(1)
                    // 路径截中间：截尾的话最有信息量的那一段（项目名）正好没了。
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white.opacity(0.58))
            // 路径比分支胶囊更该拿到宽度：分支名通常短且完整，
            // 路径被截中间的话"到底是哪个 worktree"就看不出来了。
            .layoutPriority(1)
            .help(session.cwd)

            if let branch = workspace?.info.branch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8, weight: .semibold))
                    Text(branch)
                        .font(IslandTheme.mono(10, .medium))
                    if let changes = workspace?.info.changeCount, changes > 0 {
                        Text("\(changes)△")
                            .font(IslandTheme.mono(10, .semibold))
                            .foregroundStyle(IslandTheme.waiting)
                    }
                    if let ahead = workspace?.info.ahead, ahead > 0 {
                        Text("↑\(ahead)")
                            .font(IslandTheme.mono(10, .semibold))
                            .foregroundStyle(IslandTheme.busy)
                    }
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(.white.opacity(0.08), in: .capsule)
                .fixedSize()
            }
        }
    }

    /// cwd 相对仓库根的位置。
    ///
    /// 会话开在子目录时，`~/code/foo/packages/api` 里真正有区分度的是尾部；
    /// 直接显示全路径会被中间那一大段吃掉宽度。仓库根之外的部分单独标出来。
    private var displayPath: String {
        let cwd = (session.cwd as NSString).abbreviatingWithTildeInPath
        guard let root = workspace?.root, session.cwd != root else { return cwd }
        let rootName = (root as NSString).lastPathComponent
        let suffix = session.cwd.hasPrefix(root)
            ? String(session.cwd.dropFirst(root.count))
            : ""
        return suffix.isEmpty ? cwd : rootName + suffix
    }

    // MARK: 事实行

    private var factsRow: some View {
        HStack(spacing: 12) {
            fact("运行", RelativeTime.duration(since: session.startedAt))
            fact("最后活动", RelativeTime.short(from: session.updatedAt) + "前")
            fact("PID", "\(session.pid)")
            if let terminalLabel {
                VStack(alignment: .leading, spacing: 1) {
                    Text("终端")
                        .font(IslandTheme.label(9))
                        .foregroundStyle(.white.opacity(0.38))
                    Text(terminalLabel)
                        .font(IslandTheme.label(11, .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(terminalLabel)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(IslandTheme.label(9))
                .foregroundStyle(.white.opacity(0.38))
            Text(value)
                .font(IslandTheme.label(11, .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.82))
        }
        .fixedSize()
    }

    // MARK: 最近提交

    /// 最近三条提交。
    ///
    /// 这是判断"这个会话到底干出了什么"最直接的证据 —— 状态只说它在忙，
    /// 提交历史说它忙出了什么。同项目多开时也是区分谁在推进哪条线的依据。
    @ViewBuilder
    private var commitLog: some View {
        if let commits = workspace?.recent, !commits.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(commits.prefix(2)) { commit in
                    HStack(spacing: 6) {
                        Text(commit.hash)
                            .font(IslandTheme.mono(9, .semibold))
                            .foregroundStyle(IslandTheme.busy.opacity(0.85))
                        Text(commit.subject)
                            .font(IslandTheme.label(10))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                        Text(commit.relativeDate)
                            .font(IslandTheme.label(9))
                            .foregroundStyle(.white.opacity(0.3))
                            .fixedSize()
                    }
                }
            }
        }
    }

    // MARK: 操作

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button(action: onJump) {
                Label("跳转终端", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(IslandButtonStyle(
                emphasis: .prominent, tint: accent, width: 96, height: 28
            ))

            HStack(spacing: 5) {
                iconButton("folder", help: "在 Finder 中显示") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: session.cwd
                    )
                }
                if let editor = EditorLauncher.preferred {
                    iconButton("chevron.left.forwardslash.chevron.right",
                               help: "在 \(editor.name) 中打开") {
                        editor.open(session.cwd)
                    }
                }
                // 复制的是**能直接跑的一整条命令**，不是裸的 sessionId。
                //
                // 原来这里是"复制 sessionId"，实际没有用处：sessionId 是 UUID，
                // 唯一的消费者就是 `claude --resume`，而没人会把 UUID 抄进命令行。
                // 直接给出可粘贴执行的命令，才真的省掉一步。
                iconButton("terminal", help: "复制恢复这个会话的命令") {
                    copy("cd \(session.cwd) && claude --resume \(session.sessionId)")
                }
            }

            jumpFeedback
        }
    }

    /// 跳转结果回显。
    ///
    /// 跳转是异步的（AppleScript 跨进程），不回显的话用户点完只能自己扭头
    /// 去看终端有没有动。尤其是 `bg` 会话根本不在任何终端里，必须说清楚。
    @ViewBuilder
    private var jumpFeedback: some View {
        if let jumpOutcome {
            switch jumpOutcome {
            case .focused:
                feedback("已切到该会话", IslandTheme.shell, "checkmark.circle.fill")
            case .terminalActivatedOnly:
                feedback("只前置了终端", IslandTheme.waiting, "exclamationmark.circle.fill")
            case .failed:
                feedback("没能定位", IslandTheme.danger, "xmark.circle.fill")
            }
        }
    }

    private func feedback(_ text: String, _ color: Color, _ symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8))
            Text(text).font(IslandTheme.label(9, .medium))
        }
        .foregroundStyle(color.opacity(0.9))
    }

    private func copy(_ value: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
    }

    private func iconButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(IslandButtonStyle(emphasis: .secondary, width: 28, height: 22))
        .help(help)
    }
}
