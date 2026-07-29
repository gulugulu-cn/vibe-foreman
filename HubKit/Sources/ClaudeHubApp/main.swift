import AppKit
import HubCore
import HubIPC
import HubProjects
import HubUI
import SwiftUI

// Claude Hub —— 本地 AI 编程 agent 的调度中心。
//
// 这个 target 刻意做得很薄：只负责启动 NSApplication、装配灵动岛和主窗口、
// 挂托盘图标。所有逻辑都在 HubKit 的各个库里，那些库可以 `swift test`，这里不行。

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = SessionStore()
    private let projects = ProjectStore()
    private let approvals = ApprovalCoordinator()
    private let notifications = HubNotificationCenter()

    private lazy var island = IslandController(
        store: store, approvals: approvals, projects: projects
    )
    private lazy var hooks = HookCoordinator(
        store: store, approvals: approvals,
        notifications: notifications, projects: projects
    )
    private lazy var dispatch = TerminalDispatch()

    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var approvalObserver: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory：不在 Dock 显示图标，也不占应用切换器的位置。
        // 岛和托盘就是这个 app 的全部门面。
        NSApp.setActivationPolicy(.accessory)

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
        hooks.start()
        // 清掉发起方已经死了的审批卡，见 ApprovalCoordinator.startOrphanSweep()。
        approvals.startOrphanSweep()

        // 岛上的「项目」栏可以直接启动 —— 「开发 xxx」是这个工具最高频的动作，
        // 不该要求先从菜单栏打开主窗口。
        island.onLaunch = { [weak self] project, mode in
            self?.launch(project, mode)
        }

        island.show()
        installStatusItem()
        observeApprovalQueue()

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

    func applicationWillTerminate(_ notification: Notification) {
        approvalObserver?.cancel()
        approvals.stopOrphanSweep()
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
