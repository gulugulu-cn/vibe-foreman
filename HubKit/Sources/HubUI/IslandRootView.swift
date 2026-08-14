import HubCore
import HubProbe
import HubProjects
import SwiftUI

/// 灵动岛的根视图。
///
/// 结构：`玻璃外壳` → `scrim` → `内容`。
///
/// 形态来自 `IslandModel`（`@Observable`），**不是**通过替换 rootView 切换的 ——
/// 那样做的话 SwiftUI 看到的是两棵不相干的树，动画无从发生、`@State` 每次归零。
public struct IslandRootView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let store: SessionStore
    private let approvals: ApprovalCoordinator
    private let prompts: AgentPromptCoordinator
    private let projects: ProjectStore
    private let closedSessions: ClosedSessionStore
    private let model: IslandModel
    private let geometry: NotchGeometry
    private let onToggleExpand: () -> Void
    private let onSelect: (AgentSession) -> Void
    private let onFocus: (AgentSession) -> Void
    private let onCollapse: () -> Void
    private let onLaunch: (Project, LaunchMode) -> Void
    private let onPickStalled: (StallFinding) -> Void
    private let onReply: (String) -> Void
    private let onDialogKey: (AgentPromptRequest, TerminalReply.DialogKey) -> Void

    @Namespace private var glassNamespace

    public init(
        store: SessionStore,
        approvals: ApprovalCoordinator,
        prompts: AgentPromptCoordinator,
        projects: ProjectStore,
        closedSessions: ClosedSessionStore,
        model: IslandModel,
        geometry: NotchGeometry,
        onToggleExpand: @escaping () -> Void,
        onSelect: @escaping (AgentSession) -> Void,
        onFocus: @escaping (AgentSession) -> Void,
        onCollapse: @escaping () -> Void,
        onLaunch: @escaping (Project, LaunchMode) -> Void,
        onPickStalled: @escaping (StallFinding) -> Void = { _ in },
        onReply: @escaping (String) -> Void = { _ in },
        onDialogKey: @escaping (AgentPromptRequest, TerminalReply.DialogKey) -> Void = { _, _ in }
    ) {
        self.onPickStalled = onPickStalled
        self.onReply = onReply
        self.onDialogKey = onDialogKey
        self.store = store
        self.approvals = approvals
        self.prompts = prompts
        self.projects = projects
        self.closedSessions = closedSessions
        self.model = model
        self.geometry = geometry
        self.onToggleExpand = onToggleExpand
        self.onSelect = onSelect
        self.onFocus = onFocus
        self.onCollapse = onCollapse
        self.onLaunch = onLaunch
    }

    private var state: IslandState { model.state }

    private var metrics: IslandMetrics {
        // `.nudge` 的宽度跟着**卡住的会话数**走，不是总会话数 ——
        // 用总数算的话，9 个会话里只有 1 个卡住时岛会宽得离谱，中间全是空的。
        let count = state == .nudge ? model.nudge.count : store.sessions.count
        return IslandMetrics.metrics(
            for: state, geometry: geometry, sessionCount: count
        )
    }

    private var shape: IslandShape {
        IslandShape(
            notchWidth: geometry.notchWidth,
            notchHeight: geometry.notchHeight,
            bodyWidth: metrics.bodyWidth,
            bodyHeight: metrics.bodyHeight,
            bottomRadius: metrics.bottomRadius
        )
    }

    /// 内容区顶部让出的高度。有刘海时让出刘海本身（那块被物理遮挡，画什么都看不见），
    /// 无刘海时让出胶囊的悬浮间距。
    private var contentTopInset: CGFloat {
        geometry.hasNotch ? geometry.notchHeight : 8
    }

    /// 开发期定位用：HUB_DEBUG_CONTENT=1 时给内容框描一层可见底色，
    /// 一眼看出它到底被放在哪、有没有被裁掉。
    private var debugTint: Color {
        ProcessInfo.processInfo.environment["HUB_DEBUG_CONTENT"] == "1"
            ? Color.red.opacity(0.25)
            : Color.clear
    }

    public var body: some View {
        ZStack(alignment: .top) {
            shell
            contentLayer
        }
        .frame(
            width: IslandMetrics.panelSize.width,
            height: IslandMetrics.panelSize.height,
            alignment: .topLeading
        )
        // 岛永远暗色，不跟随系统。不是审美偏好，是物理约束：岛的上半截必须和刘海
        // 严丝合缝，而刘海在浅色模式下也是纯黑 —— 做浅色岛会在刘海下沿留一条
        // 永远消不掉的黑白硬边。
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 外壳

    @ViewBuilder
    private var shell: some View {
        ZStack(alignment: .topLeading) {
            if reduceTransparency {
                // 完全兜底：关掉透明度后材质没有意义，换成接近不透明的实心底。
                shape
                    .fill(Color.black.opacity(0.97))
                    .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 1))
            } else {
                // 自控的深色材质，**不是** Liquid Glass —— 完整理由见 IslandBackdrop。
                IslandBackdrop()
                    .clipShape(shape)

                // 固定的暗色基底。这一层决定了岛的颜色，**不参与任何自适应**。
                //
                // 绕不开的算术：任何"能透出背景"的材质，在白底上都必然比在黑底上亮。
                // 试过 Liquid Glass（`.regular` / `.clear` + tint）和
                // NSVisualEffectView 的多种 material，白底下输出都落在 0.5~0.7，
                // 差别只是程度。**要在任何背景下都贴近刘海，就只能接近不透明。**
                //
                //   最终亮度 ≈ 背景亮度 × (1 − IslandTheme.baseOpacity)
                //   白底 (1.0) → 0.14      黑底 (0.0) → 0.0      刘海 → 0.0
                //
                // 留下的这 14% 正是"还能看出背后有东西"的量：透光感还在，
                // 但不足以把岛拉离刘海的色系。玻璃质感由背景模糊 + 边缘高光承担。
                shape
                    .fill(Color.black.opacity(IslandTheme.baseOpacity))
                    .allowsHitTesting(false)
            }

            // 闯入 / 审批的状态色。
            //
            // 染在材质**之上**而不是作为材质的 tint，这样它不受背景亮度影响，
            // 任何壁纸下都是同一个颜色 —— 状态色的作用是传达"出事了"，
            // 它必须是可预期的常量。
            if let shellTint {
                shape.fill(shellTint).allowsHitTesting(false)
            }

            // scrim：可读性主力，见 IslandTheme.scrim 的说明。
            shape
                .fill(IslandTheme.scrim(for: state))
                .allowsHitTesting(false)

            // 刘海 → 岛的过渡。
            //
            // 这一层专治"岛和刘海之间有一条明显分界线"：纯黑一直铺到刘海下沿，
            // 再往下用 34pt 渐隐掉。没有它的话，不透光的刘海和半透明的玻璃
            // 直接相接，边界处的亮度落差会把"岛是另外贴上去的一块东西"暴露无遗。
            if geometry.hasNotch {
                shape
                    .fill(IslandTheme.notchBlend(
                        notchHeight: geometry.notchHeight,
                        panelHeight: IslandMetrics.panelSize.height
                    ))
                    .allowsHitTesting(false)
            }

            // 边缘高光。玻璃感的关键一笔：真实玻璃的边缘因折射而比中间亮，
            // 下沿尤其明显。没有这条边，再透明也只会被读成一块半透明色块。
            shape
                .stroke(IslandTheme.edgeHighlight, lineWidth: 1)
                .allowsHitTesting(false)

            // 刘海遮蔽：物理刘海就是纯黑，这块区域画玻璃只会露馅（玻璃会透出
            // 桌面的颜色，而刘海是不透光的实体，两者对不上就会看出破绽）。
            // 画在最上层，顺便盖掉边缘高光在刘海段可能漏出的那一道亮线。
            if geometry.hasNotch {
                Rectangle()
                    .fill(.black)
                    .frame(width: geometry.notchWidth, height: geometry.notchHeight)
                    .offset(
                        x: (IslandMetrics.panelSize.width - geometry.notchWidth) / 2,
                        y: 0
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(
            width: IslandMetrics.panelSize.width,
            height: IslandMetrics.panelSize.height,
            alignment: .topLeading
        )
        .contentShape(shape)
        .onTapGesture { onToggleExpand() }
    }

    // MARK: - 内容

    /// 内容层。
    ///
    /// 顶部那块让位用的 `Color.clear` 必须 `allowsHitTesting(false)` ——
    /// `Color.clear` 是**参与命中测试**的，一块 640pt 宽的透明色压在外壳之上，
    /// 会把那一带的点击全部吃掉，外壳的 `onTapGesture` 永远不触发。
    private var contentLayer: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: contentTopInset)
                .allowsHitTesting(false)

            content
                .frame(width: metrics.bodyWidth, height: metrics.bodyHeight)
                .background(debugTint)
                // 裁到岛主体的形状（下沿有圆角），而不是一个方框 ——
                // 方框会让内容在圆角处露到玻璃外面。
                .clipShape(
                    .rect(
                        bottomLeadingRadius: metrics.bottomRadius,
                        bottomTrailingRadius: metrics.bottomRadius,
                        style: .continuous
                    )
                )
                // 形态一换就整块换掉，配合下面的 transition 做淡入淡出。
                .id(state)
                .transition(.opacity)

            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .frame(
            width: IslandMetrics.panelSize.width,
            height: IslandMetrics.panelSize.height,
            alignment: .top
        )
        // 内容比形状晚 80ms 出现（见 IslandAnimation.contentIn）。
        //
        // 这个 .animation 会**覆盖**外层 withAnimation 传下来的事务动画，
        // 从而让形状和内容用两条不同的时间曲线 —— 形状先到位、内容再浮现。
        // 这是 Dynamic Island 手感的核心，去掉它整个动效会显得廉价。
        .animation(IslandAnimation.contentIn(reduceMotion: reduceMotion), value: state)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .rest:
            RestContent(store: store, stalled: model.stalled)
                .contentShape(Rectangle())
                .onTapGesture {
                    // 跑马灯正在报某件事时，点它就该直达那件事 ——
                    // 跳到通用的会话列表等于让用户自己再找一遍刚看到的东西。
                    if let top = model.stalled.first {
                        onPickStalled(top)
                    } else {
                        onToggleExpand()
                    }
                }
        case .hover:
            HoverContent(store: store, model: model, onFocus: onFocus)
        case .expanded:
            ExpandedContent(
                store: store,
                projects: projects,
                closedSessions: closedSessions,
                model: model,
                onSelect: onSelect,
                onCollapse: onCollapse,
                onLaunch: onLaunch,
                onPickStalled: onPickStalled
            )
        case .intrusion:
            if let intrusion = model.intrusion {
                IntrusionContent(
                    event: intrusion,
                    session: store.sessions.first { $0.sessionId == intrusion.sessionId }
                )
            }
        case .approval:
            if let request = approvals.current {
                ApprovalContent(
                    request: request,
                    queueCount: approvals.queue.count,
                    onAllow: { approvals.allow(request) },
                    onDeny: { approvals.deny(request) },
                    onSkip: { approvals.skip(request) }
                )
            }
        case .nudge:
            NudgeContent(
                findings: model.nudge,
                store: store,
                model: model,
                onPick: onPickStalled
            )
        case .answer:
            if let request = model.answer {
                AnswerContent(
                    request: request,
                    onSend: onReply,
                    onJump: {
                        if let session = store.sessions.first(
                            where: { $0.sessionId == request.sessionId }
                        ) { onFocus(session) }
                    },
                    onDismiss: onCollapse,
                    feedback: model.answerFeedback,
                    onClearFeedback: { model.answerFeedback = nil }
                )
            }
        case .prompt:
            if let request = prompts.current {
                AgentPromptContent(
                    request: request,
                    queueCount: prompts.queue.count,
                    onSubmitAnswers: { prompts.submitAnswers(request, answers: $0) },
                    onChoose: { prompts.choose(request, option: $0) },
                    // 计划确认框吃不下 hook 的显式 allow（见 pressDialogKey 注释），
                    // 批准 = 放行后替用户在终端框里按 1 / 2。驳回走 hook deny 有效。
                    onApprovePlanKey: { onDialogKey(request, .digit($0)) },
                    onRejectPlan: { prompts.rejectPlan(request) },
                    onApproveEnterPlan: { onDialogKey(request, .digit(1)) },
                    onRejectEnterPlan: { prompts.rejectEnterPlan(request) },
                    onAllowPermission: { onDialogKey(request, .digit(1)) },
                    onDenyPermission: { onDialogKey(request, .escape) },
                    onGoToTerminal: {
                        // 先放行（终端原生框接管），再跳过去。找不到会话就只放行 ——
                        // 用户至少还能自己切窗口，原生框已经在等他了。
                        prompts.passthrough(request)
                        if let session = store.sessions.first(
                            where: { $0.sessionId == request.sessionId }
                        ) { onFocus(session) }
                    }
                )
                // 换卡必须重置多题表单的 @State（进度、已选答案），
                // 否则上一张卡答到第 2 题，下一张卡会从第 2 题开始。
                .id(request.id)
            }
        }
    }

    /// 闯入/审批时给外壳染上状态色，让人一眼知道这不是普通展开。
    private var shellTint: Color? {
        switch state {
        case .intrusion:
            return model.intrusion?.accent.opacity(0.26)
        case .approval:
            guard let risk = approvals.current?.risk else { return nil }
            return risk == .irreversible
                ? IslandTheme.danger.opacity(0.28)
                : IslandTheme.waiting.opacity(0.24)
        case .nudge, .answer:
            return StallPalette.color(for: model.topStallReason).opacity(0.24)
        case .prompt:
            return IslandTheme.waiting.opacity(0.24)
        default:
            // 折叠态：有东西卡着就整条下唇染色。
            // 这一层不呼吸（呼吸交给 RestContent 里的那条），它只负责底色。
            guard let reason = model.topStallReason else { return nil }
            return StallPalette.color(for: reason).opacity(0.12)
        }
    }
}

/// 滞留原因 → 颜色。断线是异常，用危险色；其余用待办色。
enum StallPalette {
    static func color(for reason: StallReason?) -> Color {
        guard let reason else { return IslandTheme.waiting }
        switch reason {
        case .interrupted: return IslandTheme.danger
        default: return IslandTheme.waiting
        }
    }
}

// MARK: - 折叠态

/// 折叠常驻内容：会话数 + 状态点阵 + waiting 徽章。
///
/// 这里**不画像素小人** —— 14 pt 高的条里放 16×16 的像素画只会糊成一坨，
/// 而且 9 个小人持续动画既是视觉噪音也是无谓能耗。小人从 hover 才出场，
/// 这也让悬停有了"奖励感"。
struct RestContent: View {
    let store: SessionStore
    /// 当前卡着的会话（含已经不再主动闯入的）。有它就上跑马灯。
    var stalled: [StallFinding] = []

    var body: some View {
        // 有东西卡着时，折叠态从"状态点阵"换成"滚动的原因"。
        //
        // 点阵回答的是"跑着几个"，而卡住的时候用户要知道的是"哪个、为什么"。
        // 点阵在这种时候是纯噪音 —— 它每一颗都长得一样。
        //
        // **只在有 stall 时才滚**，平时回到静态点阵，不引入常驻的动画耗电。
        if stalled.isEmpty {
            dots
        } else {
            NudgeTicker(stalled: stalled, store: store)
        }
    }

    private var dots: some View {
        HStack(spacing: 10) {
            // 左侧的等宽隐形占位。
            //
            // 没有它的话，徽章一出现，「计数 + 状态点」这一组就会被整体挤向左 ——
            // 整个 HStack 是居中的，但视觉重心（那排点）不在岛的对称轴上，
            // 读起来就是"歪了"。用 `.hidden()` 而不是写死一个宽度：
            // 徽章两位数时会变宽，隐形副本会跟着变，永远对得上。
            if store.waitingCount > 0 {
                WaitingBadge(count: store.waitingCount).hidden()
            }

            Text("\(store.sessions.count)")
                .font(IslandTheme.label(10, .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.78))

            HStack(spacing: 4) {
                ForEach(store.sessions.prefix(12)) { session in
                    StatusDot(status: session.status, size: 6)
                }
            }

            if store.waitingCount > 0 {
                // 折叠态**也**要能在余光里被看见。岛收起来的时候正是用户
                // 注意力在别处的时候，一个静止的小徽章会被完全忽略。
                WaitingBadge(count: store.waitingCount)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 折叠态的跑马灯 —— 卡住的会话横向滚过下唇。
///
/// 用户原话："提示虽然有个 1 但是我可能关注其他屏幕就没看到"。
/// 一个静止的小徽章在余光里等于不存在，会动的东西才会被眼角捕捉到。
///
/// 形态约束是硬的：下唇只有 14pt 高，字最大放到 9pt，所以文案必须极短
/// （`StallReason.shortLabel` 全是三个字："断线了"/"在问你"/"待验收"）。
struct NudgeTicker: View {
    let stalled: [StallFinding]
    let store: SessionStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    /// 滚动速度。pt/秒。慢到能读清，快到不会让人等。
    private static let speed: CGFloat = 22

    private var items: [(id: String, text: String, color: Color)] {
        stalled.prefix(6).map { finding in
            let name = store.sessions
                .first { $0.sessionId == finding.sessionId }?
                .name ?? finding.sessionId
            return (
                finding.sessionId,
                "\(finding.reason.symbol) \(name) \(finding.reason.shortLabel)",
                StallPalette.color(for: finding.reason)
            )
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let content = strip
            ZStack(alignment: .leading) {
                if reduceMotion {
                    // 减弱动态效果下不滚，只显示最紧急的那一条。
                    // 信息不能丢，能丢的只是动效。
                    content.frame(maxWidth: proxy.size.width, alignment: .leading)
                } else {
                    // 画两份首尾相接，位移到一份宽度时归零，得到无缝循环。
                    // 单份的话滚出去之后会有一段空白。
                    HStack(spacing: gap) {
                        content
                        content
                    }
                    .offset(x: -phase)
                    .onAppear { start(width: proxy.size.width) }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, 14)
    }

    private var gap: CGFloat { 18 }

    private var strip: some View {
        HStack(spacing: gap) {
            ForEach(items, id: \.id) { item in
                Text(item.text)
                    .font(IslandTheme.label(9, .semibold))
                    .foregroundStyle(item.color)
                    .fixedSize()
            }
        }
    }

    private func start(width: CGFloat) {
        // 估个宽度就够：滚动是循环的，估偏一点只影响循环周期，不影响观感。
        let estimated = items.reduce(CGFloat(0)) { $0 + CGFloat($1.text.count) * 9 + gap }
        guard estimated > 0 else { return }
        let duration = Double(estimated / Self.speed)
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            phase = estimated
        }
    }
}

/// 折叠态的待办徽章。带呼吸光晕。
struct WaitingBadge: View {
    let count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Text("\(count)")
            .font(IslandTheme.label(9, .bold))
            .monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, 5)
            .frame(height: 12)
            .background(IslandTheme.waiting, in: .capsule)
            .shadow(
                color: IslandTheme.waiting.opacity(breathing ? 0.85 : 0.25),
                radius: breathing ? 5 : 2
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

// MARK: - 悬停态

/// 悬停态：一排像素小人，指到谁谁抬起来并显示名字，点一下展开它的详情。
///
/// 全部小人画在**同一个 Canvas**（`SpriteRow`）里，交互靠上面叠的一层透明命中格 ——
/// 这样既保住了"单 Canvas 单时钟"的能耗设计，又拿到了逐个小人的悬停和点击。
/// 给每个小人套一个独立视图的话就是 N 个 Canvas + N 个 TimelineView。
struct HoverContent: View {
    let store: SessionStore
    let model: IslandModel
    let onFocus: (AgentSession) -> Void

    private var sessions: [AgentSession] {
        Array(store.sessions.prefix(IslandMetrics.hoverSpriteLimit))
    }

    private var hovered: AgentSession? {
        sessions.first { $0.sessionId == model.hoveredSessionId }
    }

    private var spriteSide: CGFloat { IslandMetrics.hoverSpriteSide }
    private var spacing: CGFloat { IslandMetrics.hoverSpriteSpacing }
    /// 命中格的高度 = 小人 + 抬升余量 + 状态条那一块，整格都可点。
    private var cellHeight: CGFloat {
        spriteSide + IslandMetrics.hoverLift + IslandMetrics.hoverStatusBarBlock
    }

    var body: some View {
        VStack(spacing: IslandMetrics.hoverGap) {
            SpriteScreen { screen }
            caption
        }
        .padding(.vertical, IslandMetrics.hoverVerticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 点小人之间的空隙、点摘要文字，同样要能展开 —— 否则 380pt 宽的岛
        // 只有四个 32pt 的小方块可点，其余全是死区。
        .contentShape(Rectangle())
        .onTapGesture {
            onFocus(hovered ?? store.mostUrgent ?? sessions.first ?? placeholder)
        }
    }

    /// 一个会话都没有时的兜底，避免 `onTapGesture` 里出现可选解包。
    private var placeholder: AgentSession {
        AgentSession(
            sessionId: "", pid: 0, cwd: NSHomeDirectory(), name: nil,
            status: .unknown, rawStatus: "", kind: .unknown
        )
    }

    private var screen: some View {
        ZStack(alignment: .topLeading) {
            // ① 待办高亮。**必须和命中层分开。**
            //
            // 之前把它塞进命中格里，结果那格点不动了 —— 它带 shadow 和
            // repeatForever 动画，会被合成成一个离屏层，把点击吞掉。
            // 装饰归装饰、命中归命中，中间不要互相插手。
            haloLayer

            VStack(spacing: 0) {
                SpriteRow(
                    sessions: sessions,
                    pixelSize: 2,
                    gridSize: 16,
                    spacing: spacing,
                    useMicroArt: false,
                    supportsLift: true,
                    liftedSessionId: model.hoveredSessionId
                )
                Spacer(minLength: 0)
                // 每个小人下方一条状态色横条：比色点更能在 32pt 网格下形成节律。
                HStack(spacing: spacing) {
                    ForEach(sessions) { session in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(barColor(for: session))
                            .frame(width: barWidth(for: session), height: 3)
                            .frame(width: spriteSide)
                    }
                }
            }
            .frame(height: cellHeight)
            .allowsHitTesting(false)

            hitGrid
        }
        .frame(
            width: IslandMetrics.hoverRowWidth(sessionCount: store.sessions.count),
            height: cellHeight
        )
    }

    /// 待办高亮层。**纯装饰，完全不参与命中测试。**
    ///
    /// 光有下方那条状态色横条是不够的 —— 用户的原话是
    /// "通知来了有个要处理，没有高亮提醒，就不知道哪个需要我进行下一步操作"。
    /// "该你了"必须在余光里就能被抓到，不能要求先逐个去认颜色。
    private var haloLayer: some View {
        HStack(spacing: spacing) {
            ForEach(sessions) { session in
                Group {
                    if session.status == .waiting {
                        WaitingHalo()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: spriteSide, height: cellHeight)
            }
        }
        .frame(height: cellHeight)
        .allowsHitTesting(false)
    }

    /// 叠在最上面的命中格。每格对应一个小人。
    ///
    /// 两条约束：
    ///
    /// 1. **这一层只有 `Color.clear`**，不放任何绘制内容。带 shadow 或常驻动画的
    ///    视图会被合成成离屏层，进而把点击吃掉 —— 待办高亮塞进来时就是这样，
    ///    高亮的那一格反而点不动了。
    /// 2. **格子之间不留缝。** 视觉上小人之间有 8pt 间距，但那 8pt 如果不属于
    ///    任何一格就是死区；再加上高亮光晕本来就会向外溢出，
    ///    "看起来高亮的地方"有一圈根本不可点。所以命中格按 `小人宽 + 间距`
    ///    连续平铺，间距归两侧各一半。
    private var hitGrid: some View {
        HStack(spacing: 0) {
            ForEach(sessions) { session in
                Color.clear
                    .frame(width: spriteSide + spacing, height: cellHeight)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            model.hoveredSessionId = session.sessionId
                        } else if model.hoveredSessionId == session.sessionId {
                            model.hoveredSessionId = nil
                        }
                    }
                    .onTapGesture { onFocus(session) }
                    .help(session.name ?? session.fallbackProjectName)
            }
        }
        // 平铺后总宽比小人排多出一个 spacing，向两侧各退半格，保持同轴。
        .padding(.horizontal, -spacing / 2)
    }

    private func barColor(for session: AgentSession) -> Color {
        let base = IslandTheme.color(for: session.status)
        if session.sessionId == model.hoveredSessionId { return base }
        return base.opacity(session.status == .idle ? 0.35 : 0.85)
    }

    /// 被指到的那条横条变长，作为"选中"的第二编码通道（不只靠亮度）。
    private func barWidth(for session: AgentSession) -> CGFloat {
        session.sessionId == model.hoveredSessionId ? spriteSide - 4 : 16
    }

    // MARK: 名字行

    @ViewBuilder
    private var caption: some View {
        if let hovered {
            VStack(spacing: 1) {
                Text(hovered.name ?? hovered.fallbackProjectName)
                    .font(IslandTheme.label(13, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    StatusDot(status: hovered.status, size: 5)
                    Text(statusText(for: hovered))
                        .font(IslandTheme.label(11))
                        .foregroundStyle(IslandTheme.color(for: hovered.status).opacity(0.95))
                    Text("·")
                        .font(IslandTheme.label(11))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(hovered.fallbackProjectName)
                        .font(IslandTheme.label(11))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .frame(height: IslandMetrics.hoverCaptionHeight)
            .padding(.horizontal, 12)
        } else if let urgent = store.mostUrgent {
            // **有人在等你时，默认就把它的名字顶出来。**
            //
            // 之前这里只显示 "1 忙 · 1 待办 · 1 命令 · 1 闲" 这种汇总 ——
            // 它回答了"有几个在等"，却没回答"是哪一个"，用户还是得逐个去指。
            // 而"哪个需要我下一步操作"恰恰是打开这个岛最主要的原因。
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text(urgent.name ?? urgent.fallbackProjectName)
                        .font(IslandTheme.label(13, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("在等你")
                        .font(IslandTheme.label(11))
                        .foregroundStyle(IslandTheme.waiting.opacity(0.75))
                }
                .foregroundStyle(IslandTheme.waiting)

                Text(summary)
                    .font(IslandTheme.label(10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(height: IslandMetrics.hoverCaptionHeight)
            .padding(.horizontal, 12)
        } else {
            VStack(spacing: 1) {
                Text(summary)
                    .font(IslandTheme.label(12, .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Text("指一个小人看它在干嘛，点一下展开")
                    .font(IslandTheme.label(10))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .frame(height: IslandMetrics.hoverCaptionHeight)
        }
    }

    private func statusText(for session: AgentSession) -> String {
        switch session.status {
        case .busy: return "工作中"
        case .waiting: return session.waitingFor ?? "等你输入"
        case .shell: return "跑命令"
        case .idle: return "空闲"
        case .unknown: return session.rawStatus
        }
    }

    private var summary: String {
        var parts: [String] = []
        if store.busyCount > 0 { parts.append("\(store.busyCount) 忙") }
        if store.waitingCount > 0 { parts.append("\(store.waitingCount) 待办") }
        if store.shellCount > 0 { parts.append("\(store.shellCount) 命令") }
        if store.idleCount > 0 { parts.append("\(store.idleCount) 闲") }
        return parts.isEmpty ? "没有会话" : parts.joined(separator: " · ")
    }
}

/// waiting 小人身后的呼吸光晕。
///
/// 这是"该你了"的主要视觉抓取手段。三条叠加：
/// 琥珀色是全套配色里最跳的、**只有它会动**、而且带外发光。
///
/// 呼吸周期给到 1.6 秒并且幅度克制 —— 快速闪烁在余光里是"警报"，
/// 会让人焦虑；慢呼吸是"这里有件事"，不打断当前的注意力。
struct WaitingHalo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(IslandTheme.waiting.opacity(breathing ? 0.26 : 0.13))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(IslandTheme.waiting.opacity(breathing ? 0.75 : 0.4), lineWidth: 1)
            }
            // 光晕控制在 4pt 以内：它要落在命中格里面。溢出去的那一圈
            // 看着是高亮、点下去却没反应，比不高亮更让人困惑。
            .shadow(color: IslandTheme.waiting.opacity(breathing ? 0.55 : 0.2), radius: 4)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

// MARK: - 展开态

struct ExpandedContent: View {
    let store: SessionStore
    let projects: ProjectStore
    let closedSessions: ClosedSessionStore
    let model: IslandModel
    let onSelect: (AgentSession) -> Void
    let onCollapse: () -> Void
    let onLaunch: (Project, LaunchMode) -> Void
    var onPickStalled: (StallFinding) -> Void = { _ in }

    private var selected: AgentSession? {
        store.sessions.first { $0.sessionId == model.selectedSessionId }
            ?? store.mostUrgent
            ?? store.sessions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker

            switch model.tab {
            case .sessions: sessionsBody
            case .projects: ProjectListContent(
                projects: projects, store: store, closedSessions: closedSessions,
                onJump: onSelect, onLaunch: onLaunch
            )
            }
        }
        // 终端定位要跑 AppleScript、git 要跑子进程，只在真的展开时解析（内部有节流）。
        .onAppear {
            store.resolveTerminalLabels()
            store.resolveWorkspaceGit(for: store.sessions.map(\.cwd))
        }
    }

    /// 会话 / 项目 切换。
    ///
    /// 不用系统的 `.segmented` Picker：那个控件在非活跃窗口里会整体去饱和，
    /// 和岛上其它按钮是同一个毛病（见 `IslandButtonStyle`）。
    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(IslandTab.allCases) { tab in
                let selected = model.tab == tab
                Button {
                    withAnimation(.snappy(duration: 0.18)) { model.tab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                        Text(tab == .sessions
                            ? "\(store.sessions.count)"
                            : "\(projects.projects.count)")
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(selected ? 0.55 : 0.35))
                    }
                    .font(IslandTheme.label(12, .semibold))
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.5))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        .white.opacity(selected ? 0.14 : 0),
                        in: .rect(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var sessionsBody: some View {
        VStack(spacing: 0) {
            if let selected {
                SessionDetailCard(
                    session: selected,
                    workspace: store.workspaceGit[selected.cwd],
                    terminalLabel: store.terminalLabels[selected.sessionId],
                    jumpOutcome: store.lastJump?.sessionId == selected.sessionId
                        ? store.lastJump?.outcome : nil,
                    stall: model.stalled.first { $0.sessionId == selected.sessionId },
                    onJump: { onSelect(selected) },
                    onAnswer: {
                        guard let finding = model.stalled.first(
                            where: { $0.sessionId == selected.sessionId }
                        ) else { return }
                        onPickStalled(finding)
                    }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider().opacity(0.22)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.sessions) { session in
                        SessionRowView(
                            session: session,
                            branch: store.workspaceGit[session.cwd]?.info.branch,
                            isSelected: session.sessionId == selected?.sessionId,
                            stall: model.stalled
                                .first { $0.sessionId == session.sessionId }?.reason,
                            // 点行 = 看详情。点行内的 ⇱ 按钮 = 直接跳转。
                            // 两个动作各有入口，不用"先选中再点第二下"。
                            onSelect: { model.selectedSessionId = session.sessionId },
                            onJump: { onSelect(session) }
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Hub")
                .font(IslandTheme.label(13, .semibold))
                .foregroundStyle(.white)
            Text("\(store.sessions.count) 会话")
                .font(IslandTheme.label(11))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            if store.waitingCount > 0 {
                Label("\(store.waitingCount)", systemImage: "exclamationmark.circle.fill")
                    .font(IslandTheme.label(11, .semibold))
                    .foregroundStyle(IslandTheme.waiting)
            }
            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("收起")
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.expandedHeaderHeight)
    }
}

// MARK: - 项目栏

/// 岛上的项目列表。
///
/// 存在的理由不是"也能浏览项目"，而是**把「开发 xxx」这个动作收进岛里**。
/// 在这之前，想开一个还没在跑的项目必须：点菜单栏 → 开主窗口 → 找到项目 → 启动。
/// 而这是这个工具最高频的动作。
///
/// 排序：**置顶 > 有会话在跑 > 名字**（口径见 ProjectOrdering.islandOrder）。
/// 不做搜索框：岛的 panel 基本不是 key window，文本框拿不到键盘焦点，
/// 放一个点不动的搜索框比没有更糟。要搜索去主窗口。
struct ProjectListContent: View {
    let projects: ProjectStore
    let store: SessionStore
    let closedSessions: ClosedSessionStore
    let onJump: (AgentSession) -> Void
    let onLaunch: (Project, LaunchMode) -> Void

    /// 这个项目下正在跑的会话（cwd 落在项目目录里就算）。
    private func sessions(of project: Project) -> [AgentSession] {
        let root = project.expandedPath
        return store.sessions.filter { $0.cwd == root || $0.cwd.hasPrefix(root + "/") }
    }

    private var ordered: [Project] {
        ProjectOrdering.islandOrder(
            projects.projects,
            pinned: projects.pinned,
            runningCount: { sessions(of: $0).count },
            lastCommitAt: { projects.git(for: $0)?.lastCommitAt }
        )
    }

    var body: some View {
        Group {
            if projects.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(ordered) { project in
                            ProjectRowView(
                                project: project,
                                running: sessions(of: project),
                                git: projects.git(for: project),
                                isPinned: projects.isPinned(project),
                                resumable: closedSessions.latest(
                                    forProject: project.expandedPath
                                ),
                                isMissing: projects.isMissing(project),
                                onOpen: { open(project) },
                                onLaunch: { onLaunch(project, $0) },
                                onTogglePin: { projects.togglePin(project) },
                                onRemove: { projects.remove([project]) }
                            )
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { projects.refreshGit() }
    }

    /// 点一行的默认动作：
    /// **有会话在跑就跳过去，没有就直接起一个。**
    /// 这两件事用户想要的其实是同一个 —— "让我到这个项目上去"。
    private func open(_ project: Project) {
        if let session = sessions(of: project).min(by: { $0.status < $1.status }) {
            onJump(session)
        } else {
            onLaunch(project, .claude)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("没有读到项目")
                .font(IslandTheme.label(13, .semibold))
                .foregroundStyle(IslandTheme.waiting)
            Text(projects.loadDiagnostic ?? "projects.yaml 里没有条目")
                .font(IslandTheme.label(11))
                .foregroundStyle(.white.opacity(0.55))
            if let path = projects.sourceURL?.path {
                Text(path)
                    .font(IslandTheme.mono(9))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}

/// 项目列表的一行。
///
/// 点击行为分两种：
/// - 有会话在跑：点整行跳过去（这是最高频的动作，不能多一步）。
/// - 没有会话：点整行**弹启动菜单**而不是直接起 claude ——
///   "点一下就启动了一个 Claude Code" 的误触成本太高。
struct ProjectRowView: View {
    let project: Project
    let running: [AgentSession]
    let git: GitInfo?
    let isPinned: Bool
    /// 上一个被「关窗即结束」收掉、且接得回来的会话。
    /// 有它就说明这个项目"关掉了但没干完"，菜单第一项应该是接回去而不是重开。
    var resumable: ClosedSession?
    /// 目录已经不在了。岛上的行不显示路径，所以这一档**必须有视觉标记** ——
    /// 否则一个指向已删除目录的项目看起来和正常的一模一样。
    var isMissing: Bool = false
    let onOpen: () -> Void
    let onLaunch: (LaunchMode) -> Void
    let onTogglePin: () -> Void
    var onRemove: (() -> Void)?

    @State private var isHovered = false

    /// 这个项目当前"最需要注意"的状态：拿在跑的会话里优先级最高的那个。
    private var status: SessionStatus? {
        running.min(by: { $0.status < $1.status })?.status
    }

    var body: some View {
        rowBody
            .contentShape(Rectangle())
            // 右键盖在整行上。只认右键和 ctrl+左键，左键照旧穿透下去 ——
            // 见 RightClickCatcher 里 hitTest 的说明。
            .overlay(RightClickCatcher { presentLaunchMenu() })
            .onTapGesture {
                // 有会话：跳过去。无会话：在鼠标位置弹原生启动菜单 ——
                // SwiftUI Menu 的两种整行方案都在 macOS 上翻过车
                // （label 被压扁 / 透明盖层收不到点击），见 RowMenu 注释。
                // 目录没了就别去开 —— tmux 会静默开在家目录。弹菜单让人移除。
                if running.isEmpty || isMissing {
                    presentLaunchMenu()
                } else {
                    onOpen()
                }
            }
            .onHover { isHovered = $0 }
            .help(project.expandedPath)
    }

    /// 启动菜单。整行点击（无会话时）、右键、"..." 三个入口共用，
    /// 内容也和主窗口共用同一份（`ProjectMenu`）。
    private func presentLaunchMenu() {
        RowMenu.present(
            ProjectMenu.items(
                isPinned: isPinned, resumable: resumable, isMissing: isMissing,
                onLaunch: onLaunch, onTogglePin: onTogglePin, onRemove: onRemove
            )
        )
    }

    private var rowBody: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(status.map(IslandTheme.color(for:)) ?? .white.opacity(0.14))
                .frame(width: 2, height: 28)

            // 有会话在跑就把那个人画出来 —— 一眼看出"这个项目现在有人在忙"。
            Group {
                if let session = running.min(by: { $0.status < $1.status }) {
                    PixelSprite(session: session, pixelSize: 2, gridSize: 8, useMicroArt: true)
                } else {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(IslandTheme.label(13, .semibold))
                        .foregroundStyle(.white.opacity(running.isEmpty ? 0.78 : 1))
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.5))
                            .rotationEffect(.degrees(45))
                    }
                    if isMissing {
                        Text("目录已不存在")
                            .font(IslandTheme.label(10, .medium))
                            .foregroundStyle(IslandTheme.waiting)
                    } else if running.count > 0 {
                        Text("\(running.count) 个会话")
                            .font(IslandTheme.label(10, .medium))
                            .foregroundStyle(status.map(IslandTheme.color(for:)) ?? .white)
                    }
                }
                HStack(spacing: 5) {
                    if let branch = git?.branch {
                        Text(branch)
                            .font(IslandTheme.mono(10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let changes = git?.changeCount, changes > 0 {
                        Text("\(changes)△")
                            .font(IslandTheme.mono(10, .semibold))
                            .foregroundStyle(IslandTheme.waiting.opacity(0.8))
                    }
                }
            }
            .padding(.leading, 10)

            Spacer(minLength: 8)

            // "..." = 启动菜单（继续上次、跳过权限、置顶等）。
            // 有会话的行点整行是跳会话，这里是"换一种开法"的入口；
            // 无会话的行点整行和点这里等价。
            Button {
                presentLaunchMenu()
            } label: {
                ellipsisIcon
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.3)
            .padding(.trailing, 8)
        }
        .frame(height: IslandMetrics.expandedProjectRowHeight)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isHovered ? 0.08 : 0.028))
        }
        .contentShape(Rectangle())
    }

    private var ellipsisIcon: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
    }
}

/// 展开态的一行。
///
/// 两个交互目标：
/// 1. **整行都可点**，不是只有文字可点。
/// 2. 右侧常驻快捷按钮 —— 常见操作（跳转、Finder）不该要求"先选中再点第二下"。
struct SessionRowView: View {
    let session: AgentSession
    var branch: String?
    var isSelected = false
    /// 这一行卡住了吗。卡住的行要在列表里就能被认出来 ——
    /// 否则用户得逐个点开才知道哪个在等他，而列表存在的意义正是"扫一眼"。
    var stall: StallReason?
    var onSelect: () -> Void = {}
    var onJump: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        content
            // 背景**必须常驻**（哪怕近乎透明）。
            //
            // 踩过的坑：以前只有 selected / waiting 的行才有背景，
            // 结果普通行的空白区域没有任何可命中的内容，用户只能点到文字上 ——
            // 一行 580pt 宽，真正能点的只有左边那一小截文字。
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            if isSelected {
                shape.fill(.white.opacity(0.12))
                shape.stroke(.white.opacity(0.18), lineWidth: 1)
            } else if session.status == .waiting {
                // waiting 行常驻高亮，扫一眼就能定位。
                shape.fill(IslandTheme.waiting.opacity(isHovered ? 0.16 : 0.10))
            } else {
                shape.fill(.white.opacity(isHovered ? 0.08 : 0.028))
            }
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            // 左边条编码 kind：interactive 实线，bg 半透明 —— 比塞一个图标省地方。
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(IslandTheme.color(for: session.status)
                    .opacity(session.kind == .bg ? 0.4 : 1.0))
                .frame(width: 2, height: 36)

            // 列表行用 8×8 的简化剪影（Micro art），不是把 16×16 缩小 ——
            // 那样眼睛、手指这些 1px 细节会退化成噪点。
            PixelSprite(session: session, pixelSize: 2, gridSize: 8, useMicroArt: true)
                .padding(.leading, 8)

            StatusDot(status: session.status, size: 6)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? session.sessionId)
                    .font(IslandTheme.label(13, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    // 会话名截中间：`o3-ui-memory-idempotent-fixes` 这种
                    // 名字截尾就完全认不出是哪个了。
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    Text(session.fallbackProjectName)
                        .font(IslandTheme.label(11))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                    // 分支要在**列表里**就看得到，不能只在详情卡里。
                    // 同一个项目多开时，行与行之间的唯一区别往往就是分支。
                    if let branch {
                        Text(branch)
                            .font(IslandTheme.mono(10))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.leading, 10)

            Spacer(minLength: 8)

            // 滞留徽章优先于 waitingFor：前者信息更具体
            // （"在问你" / "断线了" vs 笼统的 "input needed"），
            // 而且两个都显示会把行挤爆。
            if let stall {
                HStack(spacing: 3) {
                    Text(stall.symbol).font(.system(size: 9))
                    Text(stall.shortLabel)
                        .font(IslandTheme.label(10, .bold))
                }
                .foregroundStyle(StallPalette.color(for: stall))
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(
                    Capsule().fill(StallPalette.color(for: stall).opacity(0.16))
                )
                .padding(.trailing, 8)
            } else if let waitingFor = session.waitingFor {
                Text(waitingFor)
                    .font(IslandTheme.label(10, .semibold))
                    .foregroundStyle(IslandTheme.waiting)
                    .lineLimit(1)
                    .padding(.trailing, 8)
            }

            Text(RelativeTime.short(from: session.updatedAt))
                .font(IslandTheme.label(11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 30, alignment: .trailing)

            quickActions
        }
        .frame(height: IslandMetrics.expandedRowHeight)
    }

    /// 行内快捷按钮。
    ///
    /// 常驻占位（不是 hover 才出现）：宽度恒定，行不会因为指针经过而重排；
    /// 未悬停时压低透明度，不跟会话名抢注意力。
    private var quickActions: some View {
        HStack(spacing: 4) {
            rowButton("arrow.up.forward.app", help: "跳到这个会话的终端", action: onJump)
            rowButton("folder", help: "在 Finder 中打开") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
            }
        }
        .opacity(isHovered || isSelected ? 1 : 0.34)
        .padding(.leading, 8)
        .padding(.trailing, 10)
    }

    private func rowButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(IslandButtonStyle(emphasis: .secondary, width: 26, height: 22))
        .help(help)
    }
}

/// 相对时间。岛和主窗口共用，避免两处各写一份导致格式漂移。
public enum RelativeTime {
    public static func short(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "\(max(0, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    /// 已运行时长，用于详情卡。
    public static func duration(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let total = max(0, Int(now.timeIntervalSince(date)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}
