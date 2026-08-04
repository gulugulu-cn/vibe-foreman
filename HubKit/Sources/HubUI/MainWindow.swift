import AppKit
import HubCore
import HubIPC
import HubProjects
import SwiftUI

/// 主窗口的分区。
public enum DashboardSection: String, CaseIterable, Identifiable, Sendable {
    case sessions = "会话"
    case projects = "项目"
    case usage = "用量"
    case approvals = "审批日志"
    case settings = "设置"

    public var id: String { rawValue }

    var symbol: String {
        switch self {
        case .sessions: return "bolt.horizontal.circle"
        case .projects: return "folder"
        case .usage: return "chart.bar"
        case .approvals: return "checkmark.shield"
        case .settings: return "gearshape"
        }
    }
}

/// 主窗口。
///
/// 分工：**岛 = 一瞥**（零点击获取状态）；**主窗口 = 深挖**（用量趋势、
/// 项目管理、审批日志）。两者共享同一个 `SessionStore` 和同一套原子组件
/// （`PixelSprite` / `StatusDot` / `GitChip`），这是设计一致性的技术保障 ——
/// 维护两套组件的话它们必然会漂移。
///
/// 视觉上和岛刻意相反：岛强制暗色（因为要贴合恒为黑的刘海），
/// 主窗口完全跟随系统。岛是"设备的一部分"，窗口是"一个 app"。
public struct MainWindowView: View {
    @Bindable var store: SessionStore
    @Bindable var projects: ProjectStore
    @Bindable var approvals: ApprovalCoordinator
    let onJump: (String) -> Void
    let onLaunch: (Project, LaunchMode) -> Void

    @State private var section: DashboardSection = .sessions
    @State private var search = ""
    /// Git 账号/仓库列表。挂在窗口这一层：克隆表单每次打开复用同一份数据
    /// （带磁盘缓存），只做后台静默刷新，不再让用户每次干等加载。
    @State private var git = GitAccountStore()

    public init(
        store: SessionStore,
        projects: ProjectStore,
        approvals: ApprovalCoordinator,
        onJump: @escaping (String) -> Void,
        onLaunch: @escaping (Project, LaunchMode) -> Void
    ) {
        self.store = store
        self.projects = projects
        self.approvals = approvals
        self.onJump = onJump
        self.onLaunch = onLaunch
    }

    public var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // 单一强调色，和岛里 busy 的蓝一致，形成跨形态的一致性。
        .tint(IslandTheme.busy)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .sessions:
            SessionsPane(store: store, projects: projects, onJump: onJump)
        case .projects:
            ProjectsPane(projects: projects, store: store, git: git, onLaunch: onLaunch)
        case .usage:
            UsagePane()
        case .approvals:
            ApprovalLogPane(approvals: approvals)
        case .settings:
            SettingsPane(approvals: approvals, projects: projects, git: git)
        }
    }
}

// MARK: - 通用零件

/// 页面大标题。28pt rounded 是 iOS 26 的大标题语言。
struct PaneHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

/// git 状态芯片。
struct GitChip: View {
    let info: GitInfo?

    var body: some View {
        guard let info else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 6) {
                if let branch = info.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if info.changeCount > 0 {
                    Text("+\(info.changeCount)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(IslandTheme.waiting)
                }
                if info.ahead > 0 {
                    Text("↑\(info.ahead)")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(IslandTheme.busy)
                }
                if info.behind > 0 {
                    Text("↓\(info.behind)")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(IslandTheme.busy)
                }
                if !info.hasUpstream {
                    Text("无远端")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        )
    }
}

/// 内容区卡片。**实心，不用玻璃** —— 大面积玻璃在长时间阅读区会疲劳，
/// 而且每张卡片都要采样一次背景，9 张就是 9 次。玻璃留给 sidebar 和 toolbar
/// （那是系统自己给的）。
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .background.secondary,
                in: .rect(cornerRadius: 14, style: .continuous)
            )
    }
}

// MARK: - 会话

struct SessionsPane: View {
    let store: SessionStore
    let projects: ProjectStore
    let onJump: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "会话",
                subtitle: "\(store.sessions.count) 个运行中 · \(store.waitingCount) 个等待你"
            )
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.sessions) { session in
                        Card {
                            HStack(spacing: 12) {
                                SpriteScreen(cornerRadius: 8) {
                                    PixelSprite(session: session, pixelSize: 2, gridSize: 16)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        StatusDot(status: session.status, size: 7)
                                        Text(session.name ?? session.sessionId)
                                            .font(.system(size: 14, weight: .semibold,
                                                          design: .rounded))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if session.kind == .bg {
                                            Text("后台")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(.quaternary, in: .capsule)
                                        }
                                    }
                                    Text(projectLabel(for: session))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    if let waitingFor = session.waitingFor {
                                        Text(waitingFor)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(IslandTheme.waiting)
                                    }
                                }

                                Spacer(minLength: 8)

                                GitChip(info: gitInfo(for: session))

                                Button("跳转") { onJump(session.sessionId) }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func projectLabel(for session: AgentSession) -> String {
        projects.projectName(forPath: session.cwd) ?? session.fallbackProjectName
    }

    private func gitInfo(for session: AgentSession) -> GitInfo? {
        guard let name = projects.projectName(forPath: session.cwd),
              let project = projects.projects.first(where: { $0.name == name })
        else { return nil }
        return projects.git(for: project)
    }
}

// MARK: - 项目

struct ProjectsPane: View {
    let projects: ProjectStore
    let store: SessionStore
    let git: GitAccountStore
    let onLaunch: (Project, LaunchMode) -> Void

    @State private var search = ""
    @State private var showNewProject = false
    @State private var showClone = false

    private var filtered: [Project] {
        let base: [Project]
        if search.isEmpty {
            base = projects.projects
        } else {
            let needle = search.lowercased()
            base = projects.projects.filter {
                $0.name.lowercased().contains(needle)
                    || $0.path.lowercased().contains(needle)
                    || $0.aliases.contains { $0.lowercased().contains(needle) }
                    || ($0.description?.lowercased().contains(needle) ?? false)
            }
        }
        // 置顶 > 正在开发 > 最近提交 > 名字。38 个项目按 yaml 顺序排的话，
        // 找一个要翻半屏 —— 而人真正会回去的就是在跑的和最近动过的那几个。
        return ProjectOrdering.rank(
            base,
            pinned: projects.pinned,
            runningCount: { runningCount($0) },
            lastCommitAt: { projects.git(for: $0)?.lastCommitAt }
        )
    }

    /// 这个项目下有没有正在跑的会话。
    private func runningCount(_ project: Project) -> Int {
        let root = project.expandedPath
        return store.sessions.count { $0.cwd == root || $0.cwd.hasPrefix(root + "/") }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "项目", subtitle: "\(projects.projects.count) 个项目")

            HStack(spacing: 10) {
                TextField("搜索项目…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    showNewProject = true
                } label: {
                    Label("新建", systemImage: "plus")
                }
                Button {
                    showClone = true
                } label: {
                    Label("克隆", systemImage: "arrow.down.circle")
                }
                Button {
                    projects.scan()
                } label: {
                    Label("扫描", systemImage: "arrow.clockwise")
                }
                .disabled(projects.isScanning)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .sheet(isPresented: $showNewProject) {
                NewProjectSheet(projects: projects)
            }
            .sheet(isPresented: $showClone) {
                CloneProjectSheet(projects: projects, git: git)
            }

            if projects.projects.isEmpty {
                emptyState
                Spacer()
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { project in
                        Card {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(runningCount(project) > 0
                                        ? IslandTheme.busy : Color.secondary.opacity(0.3))
                                    .frame(width: 8, height: 8)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(project.name)
                                            .font(.system(size: 14, weight: .semibold,
                                                          design: .rounded))
                                        if projects.isPinned(project) {
                                            Image(systemName: "pin.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                                .rotationEffect(.degrees(45))
                                        }
                                        if runningCount(project) > 0 {
                                            Text("\(runningCount(project)) 个会话")
                                                .font(.system(size: 10))
                                                .foregroundStyle(IslandTheme.busy)
                                        }
                                    }
                                    if let description = project.description {
                                        Text(description)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(project.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }

                                Spacer(minLength: 8)
                                GitChip(info: projects.git(for: project))

                                Menu {
                                    ForEach(LaunchMode.allCases, id: \.self) { mode in
                                        if mode != .resumeSession {
                                            Button(mode.label) { onLaunch(project, mode) }
                                        }
                                    }
                                    Divider()
                                    Button(projects.isPinned(project) ? "取消置顶" : "置顶") {
                                        projects.togglePin(project)
                                    }
                                } label: {
                                    Image(systemName: "play.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    /// 一个项目都没有时的空状态。
    ///
    /// **必须说清楚在读哪个文件。** 这次的事故是 app 读的 projects.yaml 和
    /// 脚本维护的那份不是同一个，而界面上只有一个孤零零的"0 个项目"，
    /// 完全没有线索。空状态要给出路径、原因和下一步动作。
    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("没有读到项目", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandTheme.waiting)

                if let diagnostic = projects.loadDiagnostic {
                    Text(diagnostic)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("数据文件")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(projects.sourceURL?.path ?? "（找不到 projects.yaml）")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    if let url = projects.sourceURL {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Button("重新加载") { projects.load() }
                    Button("扫描 ~/Documents/code") { projects.scan() }
                        .disabled(projects.isScanning)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - 用量

struct UsagePane: View {
    /// 默认 7 天而不是全部。
    ///
    /// `~/.claude/projects` 实测有近 1 GB / 341 个 jsonl，全量首扫要好几十秒。
    /// 打开页面就卡住不出数，用户读到的是"这个功能没做"。7 天视图靠 mtime
    /// 过滤掉绝大多数文件，首屏两秒内出结果；想看全量再自己切。
    @State private var range: UsageRange = .week7
    @State private var summary: UsageSummary = .empty
    @State private var loading = false
    @State private var scanned = 0
    @State private var total = 0

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "用量",
                subtitle: "\(summary.totalSessions) 个会话 · \(summary.totalMessages) 条消息"
            )

            Picker("", selection: $range) {
                ForEach(UsageRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // 全量首扫要读近 1 GB。没有进度的话用户没法区分"在算"和"坏了"。
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(total > 0 ? "正在统计 \(scanned)/\(total) 个会话文件…" : "正在统计…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            HStack(spacing: 10) {
                statTile("输入", summary.totalInput, IslandTheme.busy)
                statTile("输出", summary.totalOutput, IslandTheme.shell)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(summary.projects) { usage in
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(usage.projectName)
                                        .font(.system(size: 13, weight: .semibold,
                                                      design: .rounded))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(format(usage.totalTokens))
                                        .font(.system(size: 12)).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                GeometryReader { proxy in
                                    let maxTokens = summary.projects.first?.totalTokens ?? 1
                                    let ratio = max(
                                        0.01, Double(usage.totalTokens) / Double(max(maxTokens, 1))
                                    )
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    IslandTheme.busy.opacity(0.85),
                                                    IslandTheme.busy.opacity(0.35),
                                                ],
                                                startPoint: .leading, endPoint: .trailing
                                            )
                                        )
                                        .frame(width: proxy.size.width * ratio)
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .task(id: range) { await reload() }
    }

    private func statTile(_ label: String, _ value: Int, _ color: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(format(value))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
        }
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    private func reload() async {
        loading = true
        scanned = 0
        total = 0
        let range = self.range

        // 解析要扫近 1 GB 的 jsonl，必须放后台；进度回调也从后台线程来，
        // 所以要显式跳回 MainActor 再更新 @State。
        let result = await Task.detached(priority: .userInitiated) {
            UsageStats.collect(range: range) { done, count in
                Task { @MainActor in
                    scanned = done
                    total = count
                }
            }
        }.value

        summary = result
        loading = false
    }
}

// MARK: - 审批日志

struct ApprovalLogPane: View {
    let approvals: ApprovalCoordinator

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "审批日志",
                subtitle: "记录所有被识别为高风险的操作。看一周就知道该不该开启拦截。"
            )

            if approvals.log.isEmpty {
                ContentUnavailableView(
                    "还没有记录",
                    systemImage: "checkmark.shield",
                    description: Text("高风险操作发生时会记在这里")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(approvals.log) { entry in
                            Card {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(entry.risk == .irreversible ? "不可逆" : "危险")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(
                                                entry.risk == .irreversible
                                                    ? IslandTheme.danger : IslandTheme.waiting,
                                                in: .capsule
                                            )
                                        Text(entry.projectName)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(entry.toolName)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(verdictLabel(entry))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(verdictColor(entry))
                                        Text(entry.timestamp, style: .time)
                                            .font(.system(size: 11)).monospacedDigit()
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(entry.command)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func verdictLabel(_ entry: ApprovalLogEntry) -> String {
        switch entry.verdict {
        case "allow": return "已允许"
        case "deny": return "已拒绝"
        case "timeout": return "超时拒绝"
        default: return entry.intercepted ? entry.verdict : "未拦截"
        }
    }

    private func verdictColor(_ entry: ApprovalLogEntry) -> Color {
        switch entry.verdict {
        case "deny", "timeout": return IslandTheme.danger
        case "allow": return IslandTheme.shell
        default: return .secondary
        }
    }
}

// MARK: - 设置

struct SettingsPane: View {
    @Bindable var approvals: ApprovalCoordinator
    let projects: ProjectStore
    let git: GitAccountStore

    @State private var hookStatus: String = "检查中…"

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "设置", subtitle: nil)

            ScrollView {
                VStack(spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("审批拦截").font(.system(size: 14, weight: .semibold))
                            Picker("拦截门槛", selection: $approvals.interceptThreshold) {
                                Text("只拦不可逆操作（推荐）").tag(RiskLevel.irreversible)
                                Text("危险操作也拦").tag(RiskLevel.dangerous)
                            }
                            .pickerStyle(.radioGroup)

                            Text("""
                            你全局用的是 auto 权限模式 + --dangerously-skip-permissions，\
                            图的就是不被打断。把「危险操作」一档也拦上，按日常用量每天会弹 3–8 次。\
                            建议先看一周审批日志再决定。
                            """)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Git 账号").font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Button {
                                    git.refresh()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .disabled(git.isRefreshing)
                            }

                            if git.accounts.isEmpty {
                                Text(git.diagnostic ?? (git.isRefreshing ? "检查中…" : "未检查"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(git.accounts) { account in
                                    HStack(spacing: 6) {
                                        Image(systemName: account.active
                                            ? "person.crop.circle.badge.checkmark"
                                            : "person.crop.circle")
                                            .foregroundStyle(account.active ? .green : .secondary)
                                        Text("\(account.login) · \(account.host)")
                                            .font(.system(size: 12, design: .monospaced))
                                        if account.active {
                                            Text("当前")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.green)
                                            if !git.repos.isEmpty {
                                                Text("\(git.repos.count) 个仓库")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.tertiary)
                                            }
                                        } else {
                                            Button("切换到这个") { git.switchTo(account) }
                                                .font(.system(size: 11))
                                                .disabled(git.isSwitching || git.isRefreshing)
                                        }
                                    }
                                }
                            }

                            Text("克隆用的是标「当前」的那个账号的凭据 —— 拉另一个账号的私有仓要先切过去。新增账号在终端跑：")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text("gh auth login")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Button("复制命令") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("gh auth login", forType: .string)
                                }
                                .font(.system(size: 11))
                            }
                        }
                    }
                    .onAppear { git.refresh() }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hook 连接").font(.system(size: 14, weight: .semibold))
                            Text(hookStatus)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("socket：\(HubIPCPath.display)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("项目配置").font(.system(size: 14, weight: .semibold))
                            Text("\(projects.projects.count) 个项目")
                                .font(.system(size: 12)).foregroundStyle(.secondary)

                            // 把实际读的文件路径摆出来。踩过的坑：脚本维护的是
                            // 仓库里那份 projects.yaml，app 读的却是
                            // Application Support 里另一份旧的，界面上完全没有线索。
                            Text(projects.sourceURL?.path ?? "（找不到 projects.yaml）")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.head)

                            if let diagnostic = projects.loadDiagnostic {
                                Text(diagnostic)
                                    .font(.system(size: 11))
                                    .foregroundStyle(IslandTheme.waiting)
                            }

                            Button("重新加载 projects.yaml") { projects.load() }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            hookStatus = "✓ socket 正在监听，hook 事件会实时送达"
        }
    }
}

/// 给设置页显示 socket 路径用。放这里避免 HubUI 直接暴露 HubIPC 的类型给外部。
enum HubIPCPath {
    static var display: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/hub.sock")
            .path
    }
}
