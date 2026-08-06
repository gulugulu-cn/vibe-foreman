import AppKit
import HubCore
import HubProbe
import HubProjects
import SwiftUI

/// 灵动岛的生命周期与交互控制。
///
/// 负责：建窗口、按屏幕几何定位、随形态更新命中路径、悬停探测、状态机迁移。
///
/// **形态本身不存在这里，存在 `IslandModel` 里。** 控制器只是唯一的写入口 ——
/// 这样命中路径、tracking area、外部点击监听这些 AppKit 侧的东西
/// 才有机会跟着形态一起更新。
@MainActor
public final class IslandController {

    private let store: SessionStore
    private let approvals: ApprovalCoordinator
    private let prompts: AgentPromptCoordinator
    private let projects: ProjectStore
    private let placement: IslandPlacementStore
    private let model = IslandModel()

    private var panel: IslandPanel?
    private var hostingView: IslandHostingView<AnyView>?
    private var geometry: NotchGeometry?

    private var intrusionDismissTask: Task<Void, Never>?
    /// 闯入之前是什么形态，回落时要还原。
    private var stateBeforeIntrusion: IslandState = .rest

    /// 悬停探测的兜底链路（主链路是宿主视图上的 `NSTrackingArea`）。
    private var mouseMonitor: Any?
    private var hoverExitWorkItem: DispatchWorkItem?
    private var hoverEnterWorkItem: DispatchWorkItem?

    /// 展开前要求指针在岛上**停留**多久。
    ///
    /// 没有这个延迟的话，鼠标沿菜单栏横穿去点右上角图标时岛就会弹出来 ——
    /// 用户的原话是"还没接近就立刻出来，很奇怪"。
    /// 250ms 足够滤掉路过，又不至于让有意悬停的人觉得迟钝。
    private static let hoverEnterDelay: TimeInterval = 0.25

    /// 展开态下点击岛外任意处收回。只在展开时安装，避免常驻全局监听。
    private var outsideClickMonitor: Any?

    /// 审批态的按键处理（⌘⏎ / ⎋）。
    private var keyMonitor: Any?

    /// 收缩命中区的延迟任务，见 `updateHitPath`。
    private var hitPathShrinkWork: DispatchWorkItem?

    /// 显示器配置变化的监听。插拔外接屏、改缩放都要重新对齐。
    private var screenObserver: NSObjectProtocol?

    /// 从岛上启动一个项目。由 app 层注入（要用到 TerminalDispatch）。
    public var onLaunch: ((Project, LaunchMode) -> Void)?

    public init(
        store: SessionStore,
        approvals: ApprovalCoordinator,
        prompts: AgentPromptCoordinator,
        projects: ProjectStore,
        placement: IslandPlacementStore
    ) {
        self.store = store
        self.approvals = approvals
        self.prompts = prompts
        self.projects = projects
        self.placement = placement
        placement.onChange = { [weak self] in self?.relocate() }
    }

    /// 换屏设置变了 —— 立刻挪过去。
    ///
    /// 不能复用 `realign()`：那里有 `guard geo != geometry else { return }`，
    /// 用来挡住显示器参数变化的重复通知。但用户手动切设置时，如果两块屏的
    /// 几何恰好相同（比如两台同型号外接屏），那个 guard 会让设置**看起来没生效**。
    public func relocate() {
        guard let panel, let screen = placement.screen() else { return }
        let geo = NotchGeometry(screen: screen)
        geometry = geo
        position(panel, on: geo)
        installRootView(geometry: geo)
        updateHitPath()
        HubLog.island.notice("""
        按设置重新定位 —— 屏幕 \(screen.localizedName, privacy: .public)，\
        跟随光标 \(self.placement.followsCursor, privacy: .public)
        """)
    }

    // MARK: - 生命周期

    public func show() {
        guard let screen = placement.screen() else {
            HubLog.island.error("找不到可用屏幕，灵动岛未启动")
            return
        }
        let geo = NotchGeometry(screen: screen)
        geometry = geo

        let hosting = IslandHostingView(rootView: AnyView(EmptyView()))
        hosting.frame = CGRect(origin: .zero, size: IslandMetrics.panelSize)
        hostingView = hosting

        let panel = IslandPanel(contentView: hosting)
        self.panel = panel

        position(panel, on: geo)
        // rootView **只设这一次**。之后全部靠 @Observable 驱动重绘 ——
        // 反复替换 rootView 会让动画无从发生、@State 每次归零。
        installRootView(geometry: geo)
        hosting.onPointerMove = { [weak self] point in
            self?.handlePointer(at: point)
        }
        updateHitPath()

        panel.orderFrontRegardless()
        installMouseMonitor()
        observeScreenChanges()

        HubLog.island.notice("""
        已启动 —— 屏幕 \(screen.localizedName, privacy: .public)，\
        刘海 \(Int(geo.notchWidth), privacy: .public)×\
        \(Int(geo.notchHeight), privacy: .public)pt，\
        中心 X \(geo.centerX, privacy: .public)
        """)

        applyPinnedStateIfNeeded()
    }

    public func hide() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        removeMouseMonitor()
        removeOutsideClickMonitor()
        removeKeyMonitor()
        cancelHoverEnter()
        hoverExitWorkItem?.cancel()
        hitPathShrinkWork?.cancel()
        intrusionDismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: - 定位

    /// 窗口水平居中于刘海中心，顶边贴屏幕顶。
    ///
    /// 窗口尺寸恒为 `IslandMetrics.panelSize`，形态切换只改内部布局 ——
    /// 动 window frame 会让 CoreAnimation 的隐式事务和 SwiftUI 的 spring 打架。
    private func position(_ panel: IslandPanel, on geo: NotchGeometry) {
        let size = IslandMetrics.panelSize
        panel.setFrame(
            CGRect(
                // 取整到整数点。刘海中心可能是 863.5（左右可用区不等宽），
                // 半点的窗口原点会让整块内容在 2x 屏上落到半像素，边缘发虚。
                // 岛内部的形状仍以 panel 中心对称，所以这里的取整不会引入偏移。
                x: (geo.centerX - size.width / 2).rounded(),
                y: (geo.topY - size.height).rounded(),
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    /// 显示器配置变了就重新对齐。
    ///
    /// 以前只在 `show()` 里定位一次 —— 插拔外接屏、改分辨率缩放、
    /// 甚至把内建屏在排列里挪个位置，岛都会留在旧坐标上，
    /// 表现就是"岛歪了 / 跑偏了"，而且**再也不会自己回去**。
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.realign() }
        }
    }

    private func realign() {
        guard let panel, let screen = placement.screen() else { return }
        let geo = NotchGeometry(screen: screen)
        guard geo != geometry else { return }

        geometry = geo
        position(panel, on: geo)
        installRootView(geometry: geo)
        updateHitPath()
        HubLog.island.notice("""
        显示器变化，已重新对齐 —— \(screen.localizedName, privacy: .public)，\
        刘海 \(Int(geo.notchWidth), privacy: .public)×\
        \(Int(geo.notchHeight), privacy: .public)pt
        """)
    }

    // MARK: - 内容

    private func installRootView(geometry geo: NotchGeometry) {
        hostingView?.rootView = AnyView(
            IslandRootView(
                store: store,
                approvals: approvals,
                prompts: prompts,
                projects: projects,
                model: model,
                geometry: geo,
                onToggleExpand: { [weak self] in self?.toggleExpand() },
                onSelect: { [weak self] session in self?.select(session) },
                onFocus: { [weak self] session in self?.focus(session) },
                onCollapse: { [weak self] in self?.collapse() },
                onLaunch: { [weak self] project, mode in self?.onLaunch?(project, mode) },
                onPickStalled: { [weak self] finding in self?.pickStalled(finding) },
                onReply: { [weak self] text in self?.sendReply(text) },
                onDialogKey: { [weak self] request, key in
                    self?.pressDialogKey(request, key: key)
                }
            )
        )
    }

    /// 开发期把形态钉死，方便在没法可靠控制鼠标的环境里截图核对布局。
    ///
    /// `HUB_ISLAND_STATE=hover|expanded`。生产不会设这个变量。
    private var pinnedState: IslandState? {
        switch ProcessInfo.processInfo.environment["HUB_ISLAND_STATE"] {
        case "hover": return .hover
        case "expanded", "projects": return .expanded
        case "rest": return .rest
        case "nudge": return .nudge
        case "answer": return .answer
        default: return nil
        }
    }

    private func applyPinnedStateIfNeeded() {
        guard let pinnedState else { return }
        // `projects` 顺便把展开态切到项目栏 —— 那一栏也需要能在没有鼠标的
        // 环境里截图核对。
        if ProcessInfo.processInfo.environment["HUB_ISLAND_STATE"] == "projects" {
            model.tab = .projects
        }
        // 滞留提醒是时间驱动的，真实触发要等会话安静好几分钟 ——
        // 钉住形态时必须同时喂进合成的判定结果，否则画面是空的。
        //
        // `stalled` 对**每个**形态都要喂：折叠态靠它出跑马灯，
        // 展开态靠它出滞留横幅和行内徽章。只喂 nudge/answer 的话，
        // 那两处新东西在截图里就是空的。
        if DemoFixtures.isEnabled {
            model.stalled = DemoFixtures.stallFindings()
            model.nudge = model.stalled
            model.answer = DemoFixtures.answerRequest()
        }
        model.transition(to: pinnedState)
        updateHitPath()
        // 打**实际**形态而不是环境变量的值 —— 之前只打后者，结果钉住失效时
        // 日志照样显示"已钉住"，把排查带偏了。
        HubLog.island.notice("""
        形态钉住请求 \(String(describing: pinnedState), privacy: .public)，\
        实际 \(String(describing: self.model.state), privacy: .public)，\
        滞留 \(self.model.stalled.count, privacy: .public) 条
        """)
    }

    /// 所有形态迁移的唯一入口 —— 迁移之后必须同步 AppKit 侧的命中区。
    ///
    /// 钉住时忽略**自动**迁移。以前只是在启动时设一次，紧接着悬停监听
    /// 发现指针不在岛上就把它收了回去 —— 这个调试开关等于是坏的，
    /// 而它恰恰是"没法用鼠标验证时"唯一的手段。
    ///
    /// 但**用户主动的操作必须放行**（`userInitiated: true`）。
    /// 一律冻住的代价在实机上暴露过：岛钉在展开态、又跟着光标跑到了外接屏，
    /// 用户点收起没反应，只能去杀进程 —— 一个调试开关不该能把界面卡死。
    private func setState(_ new: IslandState, userInitiated: Bool = false) {
        guard userInitiated || pinnedState == nil else { return }
        guard new != model.state else { return }
        model.transition(to: new)
        updateHitPath()
    }

    /// 命中路径 = 岛当前形状本身（折叠态额外外扩一点作为悬停热区）。
    ///
    /// 用形状而不是包围盒做命中测试很关键：折叠态上半段严格只有刘海那么宽，
    /// 用包围盒的话两侧多出的 8pt 会压在菜单栏上，把输入法、电量图标的点击吃掉。
    ///
    /// **变大立即生效，变小等动画放完。** 展开动画有 0.42s，如果命中区在动画
    /// 开始时还是折叠态的大小，用户点不到正在长出来的部分；反过来收起时
    /// 如果命中区立刻缩小，退场动画的后半段就变成了不可点的"幽灵"。
    private func updateHitPath() {
        guard let hostingView, let geometry else { return }
        hitPathShrinkWork?.cancel()
        hitPathShrinkWork = nil

        let target = hitPath(for: model.state, geometry: geometry)
        let currentArea = hostingView.hitPath.map(\.boundingBox).map { $0.width * $0.height } ?? 0
        let targetArea = target.boundingBox.width * target.boundingBox.height

        if targetArea >= currentArea {
            hostingView.hitPath = target
        } else {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, let hostingView = self.hostingView else { return }
                    hostingView.hitPath = target
                    self.hitPathShrinkWork = nil
                }
            }
            hitPathShrinkWork = work
            // 0.46s 是 IslandAnimation 里最长的一条转场（rest → expanded）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.46, execute: work)
        }
    }

    private func hitPath(for state: IslandState, geometry geo: NotchGeometry) -> CGPath {
        let metrics = IslandMetrics.metrics(
            for: state, geometry: geo, sessionCount: store.sessions.count
        )
        // 折叠态把可交互高度**只往下**多给 3pt，让那条 14pt 的细缝好点一些。
        //
        // 以前是向四周各扩 6pt（`bodyWidth + growth * 2`），加上 tracking area
        // 用包围盒近似，等效热区宽到覆盖刘海两侧的菜单栏 —— 鼠标路过就触发。
        // 横向一点都不能扩：那个方向紧挨着的就是菜单栏图标。
        let growth: CGFloat = state == .rest ? 3 : 0

        let shape = IslandShape(
            notchWidth: geo.notchWidth,
            notchHeight: geo.notchHeight,
            bodyWidth: metrics.bodyWidth,
            bodyHeight: metrics.bodyHeight + growth,
            bottomRadius: metrics.bottomRadius
        )
        let rect = CGRect(origin: .zero, size: IslandMetrics.panelSize)
        return shape.path(in: rect).cgPath
    }

    // MARK: - 悬停

    /// 来自宿主视图 `NSTrackingArea` 的指针位置（左上原点视图坐标；nil 表示离开）。
    ///
    /// 这是悬停的**主链路**。`.activeAlways` 让它在 app 未激活时照样投递，
    /// 而全局 `NSEvent` monitor 只是兜底 —— 两条链路都汇到这里。
    private func handlePointer(at point: CGPoint?) {
        guard model.state == .rest || model.state == .hover else { return }

        // **形状二次判定。** `NSTrackingArea` 只能是矩形，用的是岛形状的包围盒 ——
        // 折叠态那是 217×52pt 的一整块，横跨刘海两侧的菜单栏。只判"进没进矩形"
        // 就等于把菜单栏整条都当成了热区，鼠标去点右上角图标必然误触发。
        let inside = point.map { hostingView?.hitPath?.contains($0) ?? false } ?? false

        guard inside else {
            cancelHoverEnter()
            scheduleHoverExit()
            return
        }

        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        if model.state == .rest { scheduleHoverEnter() }
    }

    /// 指针停留够久才展开。已经排队的不重复排。
    private func scheduleHoverEnter() {
        guard hoverEnterWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.model.state == .rest else { return }
                self.hoverEnterWorkItem = nil
                // 再确认一次指针还在岛上 —— 这 250ms 里它完全可能已经走了。
                guard self.pointerIsOverIsland() else { return }
                self.setState(.hover)
            }
        }
        hoverEnterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverEnterDelay, execute: work)
    }

    private func cancelHoverEnter() {
        hoverEnterWorkItem?.cancel()
        hoverEnterWorkItem = nil
    }

    /// 当前鼠标位置是否落在岛的形状里。用屏幕坐标现算，不依赖事件。
    private func pointerIsOverIsland() -> Bool {
        guard let panel, let hitPath = hostingView?.hitPath else { return false }
        let screenPoint = NSEvent.mouseLocation
        let frame = panel.frame
        let local = CGPoint(
            x: screenPoint.x - frame.minX,
            y: frame.maxY - screenPoint.y      // Cocoa 向上 → 视图向下
        )
        return hitPath.contains(local)
    }

    private func installMouseMonitor() {
        removeMouseMonitor()
        // 兜底链路。全局 mouseMoved 监听不需要辅助功能权限（那是键盘事件才要的），
        // 但它拿不到发给本 app 自己的事件，所以单靠它会有盲区 —— 主链路是 tracking area。
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in
            Task { @MainActor in self?.handleGlobalMouseMoved() }
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// 上次检查跨屏的时刻。跨屏判定要遍历所有屏幕做矩形命中，
    /// 而 mouseMoved 每秒能来几十次 —— 必须节流。
    private var lastScreenCheck: Date = .distantPast
    private static let screenCheckInterval: TimeInterval = 0.5

    /// 指针换屏了就把岛搬过去。
    ///
    /// 这是"用户在外接屏工作时看不到提醒"的正解：岛以前锁死在内建刘海屏上，
    /// 用户看着另一块屏的时候，任何提醒在物理上都不在他视野里。
    ///
    /// **只在折叠态搬家。** 展开 / 审批 / 提醒 / 应答态搬家会把用户正在点的
    /// 东西从他手底下挪走 —— 尤其应答态，按钮位置一变，本来要点"取消"的
    /// 那一下可能落到"确认发送"上。这条不能省。
    private func followCursorAcrossScreens(force: Bool = false) {
        guard force || (model.state == .rest && pinnedState == nil) else { return }

        if !force {
            let now = Date()
            guard now.timeIntervalSince(lastScreenCheck) >= Self.screenCheckInterval
            else { return }
            lastScreenCheck = now
        }

        guard let panel, let screen = NotchGeometry.screenUnderCursor() else { return }
        let geo = NotchGeometry(screen: screen)
        guard geo != geometry else { return }

        geometry = geo
        position(panel, on: geo)
        installRootView(geometry: geo)
        updateHitPath()
        HubLog.island.notice(
            "岛跟随光标切到 \(screen.localizedName, privacy: .public)"
        )
    }

    private func handleGlobalMouseMoved() {
        followCursorAcrossScreens()

        guard let geometry else { return }
        // 展开、闯入、审批时不受悬停控制 —— 那几个态有各自的退出条件，
        // 尤其审批绝不能因为鼠标移开就消失。
        guard model.state == .rest || model.state == .hover else { return }

        let mouse = NSEvent.mouseLocation

        // 粗筛：只有指针在屏幕顶部一小条带里才继续算，其余直接返回。
        // 这只是省算力，真正的判据是下面的形状测试。
        let bandHeight = geometry.notchHeight + 48
        guard mouse.y >= geometry.topY - bandHeight, mouse.y <= geometry.topY else {
            cancelHoverEnter()
            scheduleHoverExit()
            return
        }

        // 和 tracking area 那条链路走同一套判据（形状 + 停留延迟），
        // 两条链路用不同的热区定义只会让手感变得不可预测。
        if pointerIsOverIsland() {
            hoverExitWorkItem?.cancel()
            hoverExitWorkItem = nil
            if model.state == .rest { scheduleHoverEnter() }
        } else {
            cancelHoverEnter()
            scheduleHoverExit()
        }
    }

    /// 离开热区不立刻收回：指针从岛移向岛下方内容时会短暂离开，
    /// 立刻收会闪。220ms 的延迟正好盖住这种穿越。
    private func scheduleHoverExit() {
        guard model.state == .hover, hoverExitWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.model.state == .hover else { return }
                self.model.hoveredSessionId = nil
                self.setState(.rest)
                self.hoverExitWorkItem = nil
            }
        }
        hoverExitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    // MARK: - 展开

    private func toggleExpand() {
        // 审批态点击不该收起面板 —— 那等于绕过了决策。
        guard model.state != .approval else { return }

        if model.state == .expanded {
            collapse()
        } else {
            // 没有明确选中时默认聚焦最需要处理的那个会话。
            if model.selectedSessionId == nil {
                model.selectedSessionId = (store.mostUrgent ?? store.sessions.first)?.sessionId
            }
            setState(.expanded, userInitiated: true)
            installOutsideClickMonitor()
        }
    }

    /// 点击 hover 态的某个小人 → 展开并显示它的详情。
    private func focus(_ session: AgentSession) {
        guard model.state != .approval else { return }
        model.selectedSessionId = session.sessionId
        setState(.expanded)
        installOutsideClickMonitor()
    }

    private func collapse() {
        guard model.state != .approval else { return }
        // 收起永远是用户主动的动作，钉住也必须能收 —— 否则界面会被卡死。
        setState(.rest, userInitiated: true)
        removeOutsideClickMonitor()
        // 收起时顺便回到光标所在的屏。岛跟着光标走只在折叠态生效，
        // 刚收起正是最该重新对齐的时刻（用户很可能已经换屏了）。
        followCursorAcrossScreens(force: true)
    }

    public func expand() {
        guard model.state != .approval else { return }
        if model.selectedSessionId == nil {
            model.selectedSessionId = (store.mostUrgent ?? store.sessions.first)?.sessionId
        }
        setState(.expanded)
        installOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let location = event.locationInWindow  // 全局监听里这已经是屏幕坐标
            Task { @MainActor in
                guard let self, self.model.state == .expanded else { return }
                // **必须排除落在岛自己身上的点击。**
                //
                // 全局 monitor 的契约是"发给其它 app 的事件"，但本 app 是 .accessory
                // 且从不激活，点岛的事件在系统看来并不属于某个活跃 app，于是这里照样
                // 会收到 —— 实测结果就是"点列表任何一行，岛立刻收起"，展开态等于不可用。
                guard !self.islandContains(screenPoint: location) else { return }
                self.collapse()
            }
        }
    }

    /// 屏幕坐标的点是否落在岛当前的形状里。
    ///
    /// 复用宿主视图那份 `hitPath`（左上原点），保证"能点到"和"算作岛内"
    /// 用的是同一套几何 —— 两处各算一遍迟早会漂。
    private func islandContains(screenPoint: CGPoint) -> Bool {
        guard let panel, let hitPath = hostingView?.hitPath else { return false }
        let frame = panel.frame
        let local = CGPoint(
            x: screenPoint.x - frame.minX,
            y: frame.maxY - screenPoint.y      // Cocoa 向上 → 视图向下
        )
        return hitPath.contains(local)
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: - 闯入

    /// 事件闯入：短暂膨胀提示，几秒后回落到原来的形态。
    public func presentIntrusion(_ event: IntrusionEvent) {
        // 审批优先级最高，不能被普通事件挤掉；交互卡背后有 hook 阻塞在等，
        // 同样不能被一条两秒的横幅顶掉。
        guard model.state != .approval, model.state != .prompt else { return }

        intrusionDismissTask?.cancel()
        if model.state != .intrusion { stateBeforeIntrusion = model.state }
        model.intrusion = event
        setState(.intrusion)

        // 需要用户行动的停久一点；纯"干完了"的通知快速划过就行。
        let duration: Duration = event.kind == .needsInput ? .seconds(2.6) : .seconds(2.0)
        intrusionDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.model.state == .intrusion else { return }
                self.model.intrusion = nil
                self.setState(self.stateBeforeIntrusion == .expanded ? .expanded : .rest)
            }
        }
    }

    // MARK: - 滞留提醒

    /// 上一次滞留提醒回落到哪个形态。
    private var stateBeforeNudge: IslandState = .rest

    /// 用户在岛上受理了某个滞留（跳转或应答）。上层要据此压制一轮升级。
    public var onAcknowledgeStall: ((String) -> Void)?

    /// 更新"当前有哪些卡着"。折叠态的跑马灯和下唇染色读它。
    ///
    /// 和 `presentNudge` 分开：这个**不改变形态**，只更新常驻的被动提示。
    /// 已经放弃主动闯入的会话也在这里 —— 不吵，但信息得留着。
    public func updateStalled(_ findings: [StallFinding]) {
        model.stalled = findings
    }

    /// 弹出滞留提醒。
    ///
    /// 优先级低于审批和闯入：审批在等一个不可逆操作的决策，
    /// 滞留提醒再急也不该把它挤掉。
    public func presentNudge(_ findings: [StallFinding]) {
        guard !findings.isEmpty else { return }
        guard model.state != .approval, model.state != .answer else { return }
        // 用户正在展开态里操作，不要把界面从他手底下换掉。
        guard model.state == .rest || model.state == .nudge else { return }

        nudgeDismissTask?.cancel()
        if model.state != .nudge { stateBeforeNudge = model.state }
        model.nudge = findings
        setState(.nudge)

        // 比 intrusion 停得久：这里有多个小人要认，还要给出点击的机会。
        nudgeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.model.state == .nudge else { return }
                self.model.nudge = []
                self.setState(self.stateBeforeNudge == .expanded ? .expanded : .rest)
            }
        }
    }

    private var nudgeDismissTask: Task<Void, Never>?

    /// 点了某个卡住的会话的小人。
    ///
    /// 能在岛上答的（AI 判定为提问）就进应答态；其余一律跳转过去 ——
    /// 断线、待验收这些没有"一句话就能回应"的动作，硬做成按钮是假的。
    private func pickStalled(_ finding: StallFinding) {
        nudgeDismissTask?.cancel()
        onAcknowledgeStall?(finding.sessionId)

        guard case .askedQuestion(let question) = finding.reason,
              let session = store.sessions.first(where: { $0.sessionId == finding.sessionId })
        else {
            // 不是提问的（断线、待验收、有后续）没有"一句话就能回应"的动作，
            // 但也**不该直接把人甩到终端** —— 用户点这一下是想先看清楚是什么事。
            // 展开并选中它，详情卡里有滞留横幅、分支、提交记录和跳转按钮，
            // 看完再决定去不去。
            model.expand(focusing: finding.sessionId)
            updateHitPath()
            installOutsideClickMonitor()
            return
        }

        let name = session.name ?? session.fallbackProjectName
        model.answerFeedback = nil
        model.answer = AnswerRequest(
            sessionId: finding.sessionId,
            sessionName: name,
            question: question,
            options: stallOptions[finding.sessionId] ?? [],
            target: nil
        )
        setState(.answer)

        // 目标位置要跑 tmux / AppleScript 才知道，放后台解析，回来再补上。
        // 先把面板显示出来，不要为了一行副标题卡住 UI。
        let reply = self.reply
        Task { [weak self] in
            let target = await Task.detached(priority: .userInitiated) {
                await MainActor.run { reply.locate(sessionId: finding.sessionId, session: session) }
            }.value
            await MainActor.run {
                guard let self, var current = self.model.answer,
                      current.sessionId == finding.sessionId else { return }
                current = AnswerRequest(
                    sessionId: current.sessionId, sessionName: current.sessionName,
                    question: current.question, options: current.options, target: target
                )
                self.model.answer = current
            }
        }
    }

    /// AI 给的快捷回答选项，按 sessionId 存。上层在判定时填。
    public var stallOptions: [String: [String]] = [:]

    private let reply = TerminalReply()

    /// 确认发送。**所有安全护栏在 `TerminalReply` 里**，这里只负责回显。
    private func sendReply(_ text: String) {
        guard let request = model.answer else { return }
        model.answerFeedback = "发送中…"
        let reply = self.reply
        Task { [weak self] in
            let outcome = await reply.send(text: text, to: request.sessionId)
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .sent(let target):
                    self.model.answerFeedback = "已发送 · \(target)"
                    self.onAcknowledgeStall?(request.sessionId)
                    // 发完停一下再收，让用户看清回显。
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        await MainActor.run {
                            guard self.model.state == .answer else { return }
                            self.model.answer = nil
                            self.collapse()
                        }
                    }
                case .sessionBecameBusy:
                    // 护栏①触发：用户已经自己在那边动手了。如实说，不要硬发。
                    self.model.answerFeedback = "它又开始干活了，没发"
                case .notLocated:
                    self.model.answerFeedback = "定位不到终端，请手动过去"
                case .rejected(let why):
                    self.model.answerFeedback = "内容不合法：\(why)"
                case .failed(let why):
                    self.model.answerFeedback = "发送失败：\(why)"
                    HubLog.jump.error("岛上应答失败：\(why, privacy: .public)")
                }
            }
        }
    }

    // MARK: - 审批

    /// 弹出审批面板。**不会自动回落**，必须等用户决策或超时。
    public func presentApproval() {
        intrusionDismissTask?.cancel()
        model.intrusion = nil
        removeOutsideClickMonitor()
        setState(.approval)

        // 审批要接键盘（⌘⏎ 允许 / ⏎ ⎋ 拒绝），先试着让面板成为 key window。
        // .nonactivatingPanel 保证这不会把整个 app 激活到前台。
        panel?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// 队列空了就收回去。
    public func dismissApprovalIfDone() {
        guard model.state == .approval, approvals.current == nil else { return }
        removeKeyMonitor()
        panel?.resignKey()
        // 审批清完了，如果还有交互卡压在队里，接着弹它。
        if prompts.current != nil {
            setState(.prompt)
        } else {
            setState(.rest)
        }
    }

    // MARK: - 交互作答（选择题 / 计划审批）

    /// 弹出交互作答卡。**不会自动回落**，收回由 coordinator 的超时驱动。
    ///
    /// 当前是审批态时**不抢**：审批是安全刹车，优先级更高；
    /// 交互请求的 continuation 还挂在队列里，`dismissApprovalIfDone` /
    /// `dismissPromptIfDone` 的轮询会在审批清完后把它带出来。
    public func presentPrompt() {
        guard model.state != .approval else { return }
        intrusionDismissTask?.cancel()
        model.intrusion = nil
        removeOutsideClickMonitor()
        setState(.prompt)
    }

    /// 队列空了就收回；反过来，如果岛闲着而队列里有货，把它浮出来。
    public func dismissPromptIfDone() {
        // 权限卡对应的终端对话框可能已经被用户在那边亲手答掉了 ——
        // 会话恢复干活（或直接消失）就把卡收走，别让人对着空气点「允许」。
        // 3 秒宽限：通知刚到时 store 的状态快照可能还停留在 busy。
        if let current = prompts.current,
           case .permission = current.payload,
           Date().timeIntervalSince(current.createdAt) > 3 {
            let session = store.sessions.first { $0.sessionId == current.sessionId }
            if session == nil || session?.status.isWorking == true {
                prompts.dismiss(current)
            }
        }

        if model.state == .prompt, prompts.current == nil {
            setState(.rest)
            return
        }
        if model.state == .rest || model.state == .hover, prompts.current != nil {
            presentPrompt()
        }
    }

    /// 在对应终端的对话框里替用户按一个键。权限框、计划确认框共用。
    ///
    /// 先收卡再发键（对阻塞卡收卡即放行 —— 计划确认框恰恰要先放行才会弹出：
    /// 实测 2.1.220 里 ExitPlanMode 的计划框属于 plan 状态机自己的 UI，
    /// hook 的显式 allow 压不掉它，只能放行后到框里去按键）。
    ///
    /// 带重试：放行到对话框渲染出来有一两秒窗口，期间会话还是 busy，
    /// `press` 的护栏会拒发（正确！），等一秒再试。到点还没等到就跳转
    /// 让用户自己按 —— 框还在终端里，什么都没损失。
    public func pressDialogKey(_ request: AgentPromptRequest, key: TerminalReply.DialogKey) {
        prompts.dismiss(request)
        let reply = self.reply
        let sessionId = request.sessionId
        Task { [weak self] in
            for attempt in 0..<6 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 600 : 1000))
                let outcome = await reply.press(key, sessionId: sessionId)
                switch outcome {
                case .sent:
                    return
                case .sessionBecameBusy:
                    // 对话框还没渲染出来（Claude 还在跑）。继续等。
                    continue
                case .notLocated, .rejected, .failed:
                    await MainActor.run {
                        HubLog.jump.error("对话框按键未送达，跳转让用户自己按")
                        self?.store.jump(to: sessionId)
                    }
                    return
                }
            }
            await MainActor.run {
                HubLog.jump.error("等不到对话框出现，跳转让用户自己按")
                self?.store.jump(to: sessionId)
            }
        }
    }

    /// 审批态的键盘兜底。
    ///
    /// app 是 `.accessory` 且从不激活，`makeKeyAndOrderFront` 未必真能让
    /// 这个 nonactivating panel 拿到 key —— 拿不到的话 SwiftUI 的
    /// `.keyboardShortcut` 就是死的。这里补一条**局部**监听
    /// （`addLocalMonitorForEvents` 不需要辅助功能权限）。
    ///
    /// 键位语义和面板上写的一致，且**绝不让 ⏎ 触发允许**：
    /// ⏎ / ⎋ 拒绝，⌘⏎ 允许。
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self, self.model.state == .approval,
                  let request = self.approvals.current
            else { return event }

            let isReturn = event.keyCode == 36 || event.keyCode == 76   // Return / 小键盘 Enter
            let isEscape = event.keyCode == 53

            if isReturn, event.modifierFlags.contains(.command) {
                // L3 要求长按，键盘不提供快捷放行。
                guard !request.requiresHoldToConfirm else { return nil }
                self.approvals.allow(request)
                return nil
            }
            if isReturn || isEscape {
                self.approvals.deny(request)
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - 动作

    /// 跳转。**只有真的跳到了才收起岛。**
    ///
    /// 无脑收起的话，跳转失败（会话不在任何终端里、iTerm 没开、绑定丢了）时
    /// 岛会连同失败原因一起消失，用户只知道"点了没反应"。留在展开态、
    /// 让详情卡把结果说清楚，才有下一步可走。
    private func select(_ session: AgentSession) {
        model.selectedSessionId = session.sessionId
        store.jump(to: session.sessionId) { [weak self] outcome in
            guard let self else { return }
            if case .focused = outcome { self.collapse() }
        }
    }

    /// 通知点击后的跳转入口。
    public func jumpAndCollapse(sessionId: String) {
        store.jump(to: sessionId)
        intrusionDismissTask?.cancel()
        model.intrusion = nil
        model.selectedSessionId = sessionId
        if model.state != .approval { setState(.rest) }
    }
}
