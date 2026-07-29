import AppKit
import SwiftUI

/// 灵动岛的可观察状态源。
///
/// 存在的理由：以前形态切换是靠 `hostingView.rootView = AnyView(...)` 整棵树重建的。
/// 那种做法有两个致命后果，换成 `@Observable` 之后一起消失：
///
/// 1. **动画不可能发生。** 替换 rootView 是一次性的树替换，SwiftUI 看到的是
///    "两棵不相干的树"，`withAnimation` 无从下手，`.glassEffectID` 想做的
///    「同一滴玻璃在形变」也失去了前提。写好的 `IslandAnimation` 因此一次都没被调用过。
/// 2. **所有 `@State` 归零。** 审批面板的 700ms 时间锁、长按进度、
///    `TimelineView` 的时钟，每次形态一变就被重置。
/// 展开态的两栏。
public enum IslandTab: String, CaseIterable, Sendable, Identifiable {
    /// 正在跑的会话。
    case sessions = "会话"
    /// 全部项目 —— 包括**没在跑**的，可以直接从这里启动。
    case projects = "项目"

    public var id: String { rawValue }
}

@Observable
@MainActor
public final class IslandModel {

    public private(set) var state: IslandState = .rest
    /// 上一个形态。转场动画要靠 (from, to) 这一对来选参数。
    public private(set) var previousState: IslandState = .rest

    public var intrusion: IntrusionEvent?

    /// 悬停中的小人。hover 态下方那行字实时显示它的名字和状态。
    public var hoveredSessionId: String?

    /// 被点开的会话。展开态顶部的详情卡显示它。
    public var selectedSessionId: String?

    /// 展开态看哪一栏。
    ///
    /// 加"项目"栏的理由：岛原来只能看**正在跑**的会话，想开一个新项目
    /// 或者切到一个没在跑的项目，必须先从菜单栏打开主窗口 ——
    /// 而"开发 xxx"恰恰是这个工具最高频的动作，不该要求绕一圈。
    public var tab: IslandTab = .sessions

    public init() {}

    /// 系统的"减弱动态效果"。
    ///
    /// 这里读 `NSWorkspace` 而不是 SwiftUI 的 `@Environment`：
    /// 转场动画是在**视图之外**（模型的 setter 里）选的，那个位置拿不到 environment。
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 形态迁移。**唯一**允许改 `state` 的入口。
    public func transition(to new: IslandState) {
        guard new != state else { return }
        let animation = IslandAnimation.transition(
            from: state, to: new, reduceMotion: reduceMotion
        )
        previousState = state
        withAnimation(animation) { state = new }
    }

    /// 展开并聚焦某个会话 —— 「点击小人看它的具体信息」这条路径。
    public func expand(focusing sessionId: String?) {
        if let sessionId { selectedSessionId = sessionId }
        transition(to: .expanded)
    }

    /// 内容层的淡入淡出动画。形状先到位，内容晚 80ms 浮现。
    public var contentAnimation: Animation {
        IslandAnimation.contentIn(reduceMotion: reduceMotion)
    }
}
