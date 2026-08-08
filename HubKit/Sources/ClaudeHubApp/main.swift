import AppKit
import HubCore
import HubIPC
import HubProbe
import HubProjects
import HubUI
import SwiftUI

// Claude Hub —— 本地 AI 编程 agent 的调度中心。
//
// 这个 target 刻意做得很薄：只负责启动 NSApplication、装配灵动岛和主窗口、
// 挂托盘图标。所有逻辑都在 HubKit 的各个库里，那些库可以 `swift test`，这里不行。

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // 演示模式用合成数据跑，专门给截图用 —— 真实数据里全是内部项目名和分支名。
    // 见 DemoFixtures。
    private let store = DemoFixtures.isEnabled
        ? SessionStore(reader: DemoFixtures.makeReader())
        : SessionStore()
    private let projects = DemoFixtures.isEnabled
        ? ProjectStore(yamlURL: DemoFixtures.projectsYAML)
        : ProjectStore()
    private let approvals = ApprovalCoordinator()
    private let prompts = AgentPromptCoordinator()
    private let notifications = HubNotificationCenter()
    private let placement = IslandPlacementStore()
    private let acceptance = AcceptanceStore()
    private let verifierSettings = VerifierSettings()
    /// 唯一会执行命令的组件。默认关着，由 `verifierSettings` 驱动。
    private let verifier = AcceptanceVerifier()
    /// 会话观察者：盯着开着的项目，会话停下来就按清单追问。
    private lazy var watchdog = SessionWatchdog(
        store: store, projects: projects, acceptance: acceptance
    )

    private lazy var island = IslandController(
        store: store, approvals: approvals, prompts: prompts, projects: projects,
        placement: placement
    )
    private lazy var hooks = HookCoordinator(
        store: store, approvals: approvals, prompts: prompts,
        notifications: notifications, projects: projects, acceptance: acceptance
    )
    private lazy var dispatch = TerminalDispatch()
    private lazy var stalls = StallWatcher(store: store)

    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var approvalObserver: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory：不在 Dock 显示图标，也不占应用切换器的位置。
        // 岛和托盘就是这个 app 的全部门面。
        NSApp.setActivationPolicy(.accessory)

        // 必须在任何一次读取之前把合成数据写到盘上。
        if DemoFixtures.isEnabled { DemoFixtures.materialize() }

        // 总开关 → verifier actor。
        // 不接的话用户在设置里打开了开关，verifier 那边还是关的 —— 一个默默
        // 不生效的开关比没有开关更糟。启动时也要同步一次，不能只等变化。
        verifierSettings.onChange = { [weak self] enabled in
            guard let self else { return }
            Task { await self.verifier.update(configuration: .init(enabled: enabled)) }
        }
        let verificationEnabled = verifierSettings.enabled
        Task { await verifier.update(configuration: .init(enabled: verificationEnabled)) }

        projects.load()
        projects.startGitPolling()
        store.start()

        // 通知点击 → 精准跳回对应会话的终端 tab。
        // 这是本次重写要修的核心 bug：旧实现的 terminal-notifier 拿不到点击回调。
        notifications.onActivate = { [weak self] sessionId in
            self?.island.jumpAndCollapse(sessionId: sessionId)
        }
        notifications.requestAuthorization()

        hooks.onIntrusion = { [weak self] event in
            self?.island.presentIntrusion(event)
        }
        hooks.onApprovalNeeded = { [weak self] in
            self?.island.presentApproval()
        }
        hooks.onPromptNeeded = { [weak self] in
            self?.island.presentPrompt()
        }
        hooks.start()
        // 清掉发起方已经死了的审批卡，见 ApprovalCoordinator.startOrphanSweep()。
        approvals.startOrphanSweep()
        prompts.startOrphanSweep()

        // 岛上的「项目」栏可以直接启动 —— 「开发 xxx」是这个工具最高频的动作，
        // 不该要求先从菜单栏打开主窗口。
        island.onLaunch = { [weak self] project, mode in
            self?.launch(project, mode)
        }

        // 滞留守望：岛原来只在事件发生那一瞬间提醒，之后再也不喊。
        // 用户错过那一下（在看另一块屏、或者干脆没在看）就永远错过了。
        stalls.onStalledChanged = { [weak self] findings in
            self?.island.updateStalled(findings)
        }
        stalls.onNudge = { [weak self] nudge in
            self?.present(nudge)
        }
        stalls.onOptions = { [weak self] sessionId, options in
            self?.island.stallOptions[sessionId] = options
        }
        island.onAcknowledgeStall = { [weak self] sessionId in
            self?.stalls.acknowledge(sessionId)
        }
        // 截图模式（演示数据 + 钉住形态）下不要启动守望：它 30 秒后会用
        // 自己对演示会话的判定覆盖掉预置的那一组，而演示会话没有真实的
        // transcript 和任务清单，判出来清一色是"待验收"——
        // 五类原因的区分恰恰是要展示的东西。
        let screenshotMode = DemoFixtures.isEnabled
            && ProcessInfo.processInfo.environment["HUB_ISLAND_STATE"] != nil
        if !screenshotMode { stalls.start() }

        // 盯梢本身没开销（没开着的项目直接跳过），但它会往终端注入文字 ——
        // 截图模式下绝不能起，那会往演示会话里敲字。
        if !screenshotMode { watchdog.start() }

        island.show()
        installStatusItem()
        observeApprovalQueue()

        // 截图用：主窗口平时只能从托盘菜单打开，而截图脚本没法可靠地驱动菜单。
        if ProcessInfo.processInfo.environment["HUB_OPEN_WINDOW"] == "1" {
            openMainWindow()
        }

        // 用 Logger 而不是 NSLog，且显式 `privacy: .public` —— 否则统一日志
        // 会把插值全部隐成 <private>，排障时等于没打。见 HubLog 的说明。
        let sessionCount = store.sessions.count
        let projectCount = projects.projects.count
        let source = projects.sourceURL?.path ?? "找不到 projects.yaml"
        HubLog.app.notice("""
        已就绪 —— \(sessionCount, privacy: .public) 个会话，\
        \(projectCount, privacy: .public) 个项目（\(source, privacy: .public)）
        """)
    }

    /// 把一次滞留提醒同时送到岛和通知中心。
    ///
    /// 两条路都要走：岛负责"你正看着这块屏时的余光"，
    /// 系统通知负责"你在全屏应用里、或者干脆在看别的屏"。
    private func present(_ nudge: Nudge) {
        island.presentNudge(nudge.findings)

        // 提醒是时间驱动的，没有日志就没法验证"它到底喊没喊、第几轮、为什么"——
        // 而这恰恰是最需要事后追查的一类行为。
        let summary = nudge.findings
            .map { "\($0.reason.symbol)\($0.reason.shortLabel):\($0.sessionId.prefix(8))" }
            .joined(separator: " ")
        HubLog.island.notice("""
        滞留提醒 第 \(nudge.round, privacy: .public) 轮\
        \(nudge.sound ? " 有声" : "", privacy: .public)\
        \(nudge.renotify ? " 重发通知" : "", privacy: .public) —— \
        \(summary, privacy: .public)
        """)

        guard let top = nudge.findings.first else { return }
        let session = store.sessions.first { $0.sessionId == top.sessionId }
        let name = session?.name
            ?? projects.projectName(forPath: session?.cwd ?? "")
            ?? top.sessionId

        let body: String
        switch top.reason {
        case .interrupted:
            body = "连接断了，这一轮没跑完"
        case .askedQuestion(let question):
            body = question
        case .awaitingDecision(let why):
            body = why ?? "在等你授权"
        case .unfinishedTasks(let pending, let running, let next):
            body = next.map { "还差：\($0)" } ?? "还有 \(pending + running) 项没做完"
        case .finishedAwaitingReview(let summary, _):
            body = summary ?? "完成了一轮，等你验收"
        }

        let more = nudge.findings.count > 1 ? "（另有 \(nudge.findings.count - 1) 个）" : ""
        notifications.post(
            title: "\(top.reason.symbol) \(name)\(more)",
            body: body,
            sessionId: top.sessionId,
            sound: nudge.sound,
            // 升级到这一档时必须换 identifier，否则新通知只是静默替换旧的，
            // 不会重新弹横幅 —— 用户根本看不到"又催了一次"。
            distinctBy: nudge.renotify ? "r\(nudge.round)" : nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        stalls.stop()
        watchdog.stop()
        approvalObserver?.cancel()
        approvals.stopOrphanSweep()
        prompts.stopOrphanSweep()
        hooks.stop()
        store.stop()
        projects.stopGitPolling()
        island.hide()
    }

    /// 审批队列空了就把岛收回去。
    ///
    /// 用轮询而不是回调：`ApprovalCoordinator` 的 resume 发生在 continuation 里，
    /// 让它反过来通知 UI 会把两者耦合起来。250ms 的轮询在这里完全够用，
    /// 而且只在有审批时才有意义。
    private func observeApprovalQueue() {
        approvalObserver = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.island.dismissApprovalIfDone()
                self?.island.dismissPromptIfDone()
            }
        }
    }

    // MARK: - 托盘

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "circle.hexagongrid.fill",
            accessibilityDescription: "Claude Hub"
        )

        let menu = NSMenu()
        menu.addItem(
            withTitle: "打开主窗口", action: #selector(openMainWindow), keyEquivalent: "o"
        ).target = self
        menu.addItem(
            withTitle: "展开灵动岛", action: #selector(expandIsland), keyEquivalent: "e"
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r"
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出 Claude Hub", action: #selector(quit), keyEquivalent: "q"
        ).target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func refresh() {
        store.refresh()
        projects.refreshGit()
    }

    @objc private func expandIsland() {
        island.expand()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 主窗口

    @objc private func openMainWindow() {
        if let mainWindow {
            // 主窗口要抢焦点，所以这里才 activate；岛是 nonactivating 的，不受影响。
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        let root = MainWindowView(
            store: store,
            projects: projects,
            approvals: approvals,
            placement: placement,
            acceptance: acceptance,
            verifierSettings: verifierSettings,
            verifier: verifier,
            watchdog: watchdog,
            channels: hooks.channels,
            onJump: { [weak self] sessionId in
                self?.store.jump(to: sessionId)
            },
            onLaunch: { [weak self] project, mode in
                self?.launch(project, mode)
            }
        )

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Hub"
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 780, height: 520)

        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func launch(_ project: Project, _ mode: LaunchMode) {
        let dispatch = self.dispatch
        let name = project.name
        let path = project.expandedPath
        // AppleScript + tmux 有跨进程成本，别卡住 UI。
        Task.detached(priority: .userInitiated) {
            dispatch.open(project: name, path: path, mode: mode)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
