import SwiftUI

/// 岛的外形。
///
/// 两种形态共用一个 `Shape` 实现，靠 `notchHeight == 0` 区分 —— 这样
/// 主屏和外接屏走的是同一套状态机和同一条动画路径，只是几何参数不同。
///
/// ## 主屏（有刘海）：下唇形
///
/// 关键约束是**上窄下宽**：`y ∈ [0, notchHeight]` 这一段宽度严格等于刘海宽，
/// 一分不多 —— 多出来就会压住菜单栏两侧的图标。超过刘海高度之后才向两侧扩张，
/// 中间用一个向外凸的反向圆角过渡，做出"从刘海里挤出来"的液体感。
///
/// 上半段被物理刘海完全遮住，画什么都看不见，但**必须画**：Liquid Glass 的
/// 采样和形变需要一个连续的形状，从 y=0 开始才能让岛看起来是长在刘海上而不是贴在下面。
///
/// ## 外接屏（无刘海）：独立胶囊
///
/// 不做"半个下唇" —— 没有刘海托着，缺失的上半截会被读成渲染 bug。
/// 改成距屏幕顶 `pillTopInset` 悬浮的独立圆角矩形，是个自洽的设计。
public struct IslandShape: Shape, Sendable {
    /// 刘海宽。0 表示这块屏没有刘海，走胶囊形态。
    public var notchWidth: CGFloat
    /// 刘海高（= safeAreaInsets.top）。
    public var notchHeight: CGFloat
    /// 岛主体宽度（下半段）。
    public var bodyWidth: CGFloat
    /// 岛主体高度（刘海以下露出来的部分）。
    public var bodyHeight: CGFloat
    /// 下沿圆角。
    public var bottomRadius: CGFloat
    /// 无刘海时的顶部悬浮间距。
    public var pillTopInset: CGFloat

    /// 反向圆角半径。比刘海物理底角略小，视觉上才像"融进刘海"；
    /// 比它大会读成两个东西叠在一起。
    private let inverseRadius: CGFloat = 6

    public init(
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        bodyWidth: CGFloat,
        bodyHeight: CGFloat,
        bottomRadius: CGFloat,
        pillTopInset: CGFloat = 8
    ) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.bodyWidth = bodyWidth
        self.bodyHeight = bodyHeight
        self.bottomRadius = bottomRadius
        self.pillTopInset = pillTopInset
    }

    /// 让 SwiftUI 能对形状本身做插值动画。
    ///
    /// 这是形变连续的保底手段：即使 `.glassEffectID` 的形变没有按预期生效，
    /// 形状本身也会平滑过渡，不会出现跳变。
    public var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(bodyWidth, bodyHeight),
                AnimatablePair(bottomRadius, notchWidth)
            )
        }
        set {
            bodyWidth = newValue.first.first
            bodyHeight = newValue.first.second
            bottomRadius = newValue.second.first
            notchWidth = newValue.second.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        notchHeight > 0 && notchWidth > 0
            ? notchedPath(in: rect)
            : pillPath(in: rect)
    }

    // MARK: - 有刘海

    private func notchedPath(in rect: CGRect) -> Path {
        let cx = rect.midX
        let halfTop = notchWidth / 2
        let halfBody = max(halfTop, bodyWidth / 2)

        let yTop = rect.minY
        let yShoulder = yTop + notchHeight          // 刘海下沿，开始扩张的位置
        let yBottom = yShoulder + bodyHeight

        // 主体比刘海宽出来的量。它决定反向圆角能画多大。
        let overhang = halfBody - halfTop
        // 反向圆角不能超过可用的水平/垂直空间，否则路径会自交，渲染出诡异的尖刺。
        let ir = max(0, min(inverseRadius, min(overhang, bodyHeight / 2)))
        // 下沿圆角同理受限于主体尺寸。
        let br = max(0, min(bottomRadius, min(halfBody, bodyHeight)))

        var path = Path()

        // 左上：从刘海左沿垂直下来（这一段严格贴着刘海宽度，不侵占菜单栏）
        path.move(to: CGPoint(x: cx - halfTop, y: yTop))
        path.addLine(to: CGPoint(x: cx - halfTop, y: yShoulder - ir))

        // 反向圆角：向左外凸，把垂直边过渡到水平的肩线
        if ir > 0 {
            path.addQuadCurve(
                to: CGPoint(x: cx - halfTop - ir, y: yShoulder),
                control: CGPoint(x: cx - halfTop, y: yShoulder)
            )
        }

        // 肩线向左延伸到主体左沿
        path.addLine(to: CGPoint(x: cx - halfBody, y: yShoulder))
        // 左侧竖边
        path.addLine(to: CGPoint(x: cx - halfBody, y: yBottom - br))
        // 左下圆角
        if br > 0 {
            path.addQuadCurve(
                to: CGPoint(x: cx - halfBody + br, y: yBottom),
                control: CGPoint(x: cx - halfBody, y: yBottom)
            )
        }
        // 下沿
        path.addLine(to: CGPoint(x: cx + halfBody - br, y: yBottom))
        // 右下圆角
        if br > 0 {
            path.addQuadCurve(
                to: CGPoint(x: cx + halfBody, y: yBottom - br),
                control: CGPoint(x: cx + halfBody, y: yBottom)
            )
        }
        // 右侧竖边回到肩线
        path.addLine(to: CGPoint(x: cx + halfBody, y: yShoulder))
        // 肩线向右收回到刘海右沿
        path.addLine(to: CGPoint(x: cx + halfTop + ir, y: yShoulder))
        // 右侧反向圆角
        if ir > 0 {
            path.addQuadCurve(
                to: CGPoint(x: cx + halfTop, y: yShoulder - ir),
                control: CGPoint(x: cx + halfTop, y: yShoulder)
            )
        }
        // 回到起点
        path.addLine(to: CGPoint(x: cx + halfTop, y: yTop))
        path.closeSubpath()

        return path
    }

    // MARK: - 无刘海

    private func pillPath(in rect: CGRect) -> Path {
        let width = max(1, bodyWidth)
        let height = max(1, bodyHeight)
        let box = CGRect(
            x: rect.midX - width / 2,
            y: rect.minY + pillTopInset,
            width: width,
            height: height
        )
        // .continuous 是 macOS 26 的圆角语言；老式的 .circular 会显得生硬。
        let radius = min(bottomRadius, min(width, height) / 2)
        return Path(roundedRect: box, cornerRadius: radius, style: .continuous)
    }
}
