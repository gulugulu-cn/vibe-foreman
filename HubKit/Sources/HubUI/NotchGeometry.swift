import AppKit

/// 一块屏幕的刘海几何。
///
/// **所有布局都必须写成这里几个属性的函数，绝不能出现字面量。**
/// 用户改显示分辨率缩放时刘海的 pt 尺寸会变；换机器更是完全不同的值。
///
/// 本机实测（16" M4 Max，默认缩放 1728×1117）：
/// - 内建屏：notchWidth = 185，notchHeight = 32，菜单栏高 33，中心 X = 864
/// - 外接 LG 4K（1920×1080）：无刘海，safeAreaInsets.top = 0
///
/// 注意实测值和常见的"200×37"传闻并不一致 —— 这正是不能硬编码的理由。
public struct NotchGeometry: Equatable, Sendable {
    public let screenFrame: CGRect
    public let notchWidth: CGFloat
    public let notchHeight: CGFloat
    /// 刘海的**真实**中心（屏幕坐标）。
    ///
    /// 不能直接用 `screenFrame.midX`：本机实测左侧可用区宽 771、右侧 772，
    /// 刘海中心是 863.5 而屏幕中心是 864 —— 差半个点。数值不大，但岛是**贴着**
    /// 刘海画的，任何偏移都会在交界处露出一条不对称的边。既然系统把两侧的
    /// 真实宽度都给了，就没有理由去假设它对称。
    public let notchCenterX: CGFloat

    public var hasNotch: Bool { notchWidth > 0 && notchHeight > 0 }

    /// 岛的对称轴。有刘海时贴刘海中心，无刘海时用屏幕中心。
    public var centerX: CGFloat { hasNotch ? notchCenterX : screenFrame.midX }

    /// 屏幕顶边（Cocoa 坐标系，y 向上）。
    public var topY: CGFloat { screenFrame.maxY }

    public init(
        screenFrame: CGRect,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        notchCenterX: CGFloat? = nil
    ) {
        self.screenFrame = screenFrame
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.notchCenterX = notchCenterX ?? screenFrame.midX
    }

    public init(screen: NSScreen) {
        self.screenFrame = screen.frame

        // auxiliaryTopLeftArea / auxiliaryTopRightArea 是刘海**两侧**的可用菜单栏区域。
        // 两者都存在才说明有刘海；无刘海的屏幕这两个属性返回 nil。
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = max(0, screen.frame.width - left.width - right.width)
            self.notchWidth = width
            self.notchHeight = screen.safeAreaInsets.top
            // 左侧可用区的右边界就是刘海的左沿，加半个刘海宽即中心。
            self.notchCenterX = left.maxX + width / 2
        } else {
            self.notchWidth = 0
            self.notchHeight = 0
            self.notchCenterX = screen.frame.midX
        }
    }

    /// 当前应该承载岛的屏幕。
    ///
    /// 默认取内建屏（有刘海那块）—— 心智模型是"岛长在刘海上"，
    /// 它不该因为鼠标移到副屏就跟着跑。找不到带刘海的屏幕就退回主屏。
    public static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main
    }

    /// 鼠标当前所在的屏幕。审批弹窗用它 —— 那种要用户立刻决策的东西
    /// 必须出现在用户正在看的地方，而不是固定在内建屏。
    /// 岛该出现在哪块屏上 —— **光标所在的那块**，没有就回到有刘海的那块。
    ///
    /// 以前一律用 `preferredScreen()`（永远是内建的刘海屏），于是用户在外接屏
    /// 上工作时，岛在物理上就不在他的视野里。他的原话是
    /// "我可能关注其他屏幕就没看到" —— 这条不解决，跑马灯、呼吸、主动闯入
    /// 全都是白做的。
    ///
    /// 旁边的 `screenUnderCursor()` 其实一开始就写好了，只是全项目零调用。
    public static func activeScreen() -> NSScreen? {
        screenUnderCursor() ?? preferredScreen()
    }

    public static func screenUnderCursor() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}
