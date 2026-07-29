import AppKit
import SwiftUI

/// 承载灵动岛的窗口。
///
/// 几个设置都不是可选项：
/// - `.borderless` + `.nonactivatingPanel`：点岛不该把 Claude Hub 变成前台 app，
///   否则用户点一下就丢了当前 app 的焦点。
/// - `level = .statusBar`（25）：压过 `.mainMenu`（24），这样岛能盖在菜单栏之上。
/// - `.fullScreenAuxiliary`：别的 app 全屏时岛依然可见 —— 你在全屏 IDE 里写代码时
///   恰恰最需要看到 agent 状态。
/// - `hasShadow = false`：系统阴影会绕着整个 640×720 的透明矩形画，必须自己画。
public final class IslandPanel: NSPanel {

    public init(contentView: NSView) {
        super.init(
            contentRect: CGRect(origin: .zero, size: IslandMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        animationBehavior = .none
        // 没有这行，窗口根本收不到 mouseMoved —— NSTrackingArea 的 .mouseMoved
        // 选项也就成了摆设。默认是 false。
        acceptsMouseMovedEvents = true
        // 岛不参与窗口循环，也不该出现在 Mission Control 的窗口列表里。
        collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        level = .statusBar

        self.contentView = contentView
    }

    /// 审批态要接 ⌘⏎ / ⎋，所以必须能成为 key window。
    /// 但 `.nonactivatingPanel` 保证成为 key 不会把整个 app 激活到前台。
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

/// 做逐像素点击穿透的宿主视图。
///
/// 窗口是 640×720 的大透明块。不处理的话，它会吞掉整个屏幕顶部中间区域的所有点击 ——
/// 用户点菜单栏、点下面的窗口全都失灵。
///
/// 这里不用矩形近似，直接**拿岛当前的形状路径做命中测试**：
/// 折叠态上半段严格只有刘海那么宽，两侧的菜单栏图标依然可点；
/// 形状变了命中区自动跟着变，不用维护两套几何。
public final class IslandHostingView<Content: View>: NSHostingView<Content> {

    /// 当前可交互区域（左上原点的 SwiftUI 坐标系）。由控制器随形态更新。
    /// 为 nil 时整个窗口穿透。
    public var hitPath: CGPath? {
        didSet { rebuildTrackingArea() }
    }

    /// 指针进出岛的回调。悬停探测的**主链路**。
    ///
    /// 参数是指针在视图坐标系（左上原点）里的位置；离开时为 nil。
    public var onPointerMove: ((CGPoint?) -> Void)?

    private var trackingArea: NSTrackingArea?

    // MARK: - 点击派发

    /// **整个「岛点不动」问题的解药。**
    ///
    /// AppKit 的规则：点击一个**非 key 窗口**时，如果目标视图的
    /// `acceptsFirstMouse` 返回 false，这次点击只用来切换 key 状态，
    /// **不会派发给视图**。`NSHostingView` 默认就是返回 false。
    ///
    /// 而这个 app 是 `.accessory`（永远不是活跃 app）、panel 是
    /// `.nonactivatingPanel`（点它不激活也基本不成为 key），
    /// 于是**每一次点击都算 "first mouse"，全部被丢弃** ——
    /// 展开、列表行、审批按钮，一个都点不动。
    ///
    /// 返回 true 让点击直接进 SwiftUI，同时保持「不抢焦点」这个前提不变。
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitPath else { return nil }
        // hitTest 收到的点在 superview 坐标系里。
        let local = convert(point, from: superview)
        guard hitPath.contains(topLeftOrigin(local)) else { return nil }
        return super.hitTest(point)
    }

    /// 把本视图坐标系里的点换算成 `hitPath` 所在的左上原点坐标系。
    ///
    /// **不能假设 `isFlipped` 恒为 true。** SDK 里 `NSHostingView.isFlipped` 是
    /// 一个 `final` 的**可读写**属性，既不能覆写、默认值也不属于契约的一部分。
    /// 猜错的话命中区会整体翻到窗口底部 —— 720pt 高的窗口，岛在顶部 46pt，
    /// 翻过来就落在屏幕中间的空气里，整个岛完全点不动，且没有任何报错。
    private func topLeftOrigin(_ local: CGPoint) -> CGPoint {
        isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
    }

    /// 事件里的 `locationInWindow` → 左上原点坐标。
    private func pointerLocation(of event: NSEvent) -> CGPoint {
        topLeftOrigin(convert(event.locationInWindow, from: nil))
    }

    // MARK: - 悬停

    /// 悬停探测的主链路是 `NSTrackingArea`，不是全局 `NSEvent` monitor。
    ///
    /// 关键在 `.activeAlways`：它让 mouseEntered / mouseExited / mouseMoved
    /// 在**本 app 未激活**时照样投递 —— 这正是菜单栏类 app 的标准做法。
    /// 默认的 `.activeInKeyWindow` 对一个永远不是 key 的 panel 等于什么都不做。
    ///
    /// 控制器里那个全局 monitor 保留着，但降级为兜底：两条链路都指向同一个
    /// 状态机，只用一条就是单点失效。
    private func rebuildTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil

        guard let hitPath else { return }
        // 用路径包围盒做 tracking rect（tracking area 只支持矩形）。
        // 精确的形状判定仍然在 hitTest 里做，所以这里宽松一点不会造成误点击 ——
        // 只是让"接近岛"就能开始探测，本来就是想要的行为。
        var rect = hitPath.boundingBox
        guard !rect.isEmpty else { return }
        if !isFlipped {
            rect.origin.y = bounds.height - rect.maxY
        }

        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerMove?(pointerLocation(of: event))
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMove?(pointerLocation(of: event))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerMove?(nil)
    }
}
