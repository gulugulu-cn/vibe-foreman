import SwiftUI
import HubCore

/// 岛的视觉常量。
public enum IslandTheme {

    // MARK: - 状态色

    /// waiting 用琥珀而不是红：红要留给「破坏性/不可逆」（审批的 L3、进程崩溃）。
    /// waiting 表达的是"该你了"，不是"出事了"。而且琥珀在暗背景上比红更跳 ——
    /// 红容易被深色壁纸吞掉。
    public static let busy = Color(red: 0.31, green: 0.66, blue: 1.00)      // #4FA8FF
    public static let waiting = Color(red: 1.00, green: 0.69, blue: 0.13)   // #FFB020
    public static let shell = Color(red: 0.20, green: 0.84, blue: 0.29)     // #32D74B
    public static let danger = Color(red: 1.00, green: 0.27, blue: 0.23)    // #FF453A

    /// idle 用的中性灰。
    ///
    /// 实测教训：系统的 `#8E8E93` 放在压过 scrim 的深色玻璃上几乎完全看不见 ——
    /// 那个值是给浅色背景设计的。这里提亮到接近白，靠**透明度**而不是**灰度**
    /// 来表达"不活跃"，才能在暗底上既可见又克制。
    public static let idle = Color(red: 0.85, green: 0.86, blue: 0.88)

    public static func color(for status: SessionStatus) -> Color {
        switch status {
        case .busy: return busy
        case .waiting: return waiting
        case .shell: return shell
        case .idle, .unknown: return idle
        }
    }

    // MARK: - 可读性

    /// 岛的固定暗度。**决定岛的颜色，不参与任何背景自适应。**
    ///
    /// 绕不开的算术：任何"能透出背景"的材质，在白底上都必然比在黑底上亮。
    /// 实测过 Liquid Glass（`.regular` / `.clear` + 黑 tint）和
    /// NSVisualEffectView 的多种 material，白底下输出都落在 0.5~0.7 之间，
    /// 差别只是程度 —— 而刘海恒为 0。**要在任何背景下都贴合刘海，只能接近不透明。**
    ///
    ///     最终亮度 ≈ 背景亮度 × (1 − baseOpacity)
    ///     白底 (1.0) → 0.14      黑底 (0.0) → 0.0      刘海 → 0.0
    ///
    /// 0.86 是"看得出背后有东西"和"看不出和刘海有色差"的交界：
    /// 再低白底下就开始发灰，再高就成了一块死黑的塑料。
    public static let baseOpacity: Double = 0.86

    /// 玻璃之上、内容之下的遮罩。
    ///
    /// 这是文字可读性的**主力手段**，不是逐字加阴影。Liquid Glass 高度透明，
    /// 壁纸一换文字就可能完全读不出来；scrim 随形状一起裁切，成本近乎为零，
    /// 效果远好于给每个 Text 挂 shadow（那还会在半透明背景上糊出一圈脏边）。
    ///
    /// 但**压太狠玻璃就没了**：初版这里是 0.42→0.16，配上纯黑的刘海遮蔽区，
    /// 整个岛看起来像一块深色塑料而不是玻璃。现在压到刚够读的程度，
    /// 剩下的可读性交给 `edgeHighlight` 的边缘高光和文字本身的字重。
    public static func scrim(for state: IslandState) -> LinearGradient {
        // 配的是 `.clear` 玻璃（不做亮度自适应），所以这一层同时承担两件事：
        // 保证文字可读，以及把岛的亮度**钉在刘海附近**。数值偏重是有意的。
        // 这一层现在**只管可读性**，不再兼职"把材质压暗" ——
        // 岛的颜色由 `baseOpacity` 那层固定基底决定，和背景无关。
        //
        // 展开和审批要重一些：那两个形态要**读密集文字**，
        // 背后窗口透过来的那 14% 亮度会和小字打架（实测岛飘在 Finder 上时
        // 文件名的轮廓会浮在会话名下面）。
        let (top, bottom): (Double, Double) = switch state {
        case .rest: (0.12, 0.06)
        case .hover: (0.14, 0.06)
        case .expanded: (0.28, 0.20)
        case .intrusion: (0.16, 0.08)
        case .approval: (0.34, 0.26)
        }
        return LinearGradient(
            colors: [.black.opacity(top), .black.opacity(bottom)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 刘海与岛之间的过渡。
    ///
    /// **消除硬边用的。** 物理刘海是纯黑不透光的实体，岛是半透明玻璃；
    /// 两者直接相接时会在 `y = notchHeight` 处留下一条黑 / 亮的硬边，
    /// 一眼就能看出"岛是贴上去的另一个东西"，而不是"从刘海里流出来的"。
    ///
    /// 解法是让纯黑往下渐隐 `blendDepth` 那么长的一段。渐隐区间必须足够长
    /// （比刘海本身还高），太短会从"一条硬边"变成"一条软边"，问题性质没变。
    public static func notchBlend(notchHeight: CGFloat, panelHeight: CGFloat) -> LinearGradient {
        let blendDepth: CGFloat = 44
        let solidEnd = notchHeight / panelHeight
        let fadeEnd = (notchHeight + blendDepth) / panelHeight
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: solidEnd),
                .init(color: .black.opacity(0), location: fadeEnd),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 玻璃边缘的高光。
    ///
    /// 这是"看起来像玻璃"最关键的一笔：真实玻璃的边缘会因为折射而比中间亮，
    /// 下沿尤其明显（光从上方进入、在底面全反射）。没有这条边，再透明的
    /// 材质也只会被读成"一块半透明色块"。
    ///
    /// 顶部给 0：那一段被纯黑的刘海遮蔽区盖着，画了也看不见，
    /// 反而可能在遮蔽区边缘漏出一道亮线。
    public static let edgeHighlight = LinearGradient(
        stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0.10), location: 0.35),
            .init(color: .white.opacity(0.30), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - 字体

    /// 正文用 SF Rounded：它和 Liquid Glass 的圆润语言同源，
    /// 且圆体在半透明背景上的字重感知比 SF Pro 更实。
    public static func label(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// 路径、分支名、命令一律等宽。
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// 岛上按钮的样式。
///
/// **不能用系统的 `.glass` / `.glassProminent`。** 岛的 panel 是
/// `.nonactivatingPanel` 且这个 app 是 `.accessory`，绝大多数时候都不是 key window，
/// 而 AppKit 会把非活跃窗口里的系统按钮**整体去饱和** —— 实测「跳转终端」和
/// 审批的「允许/拒绝」都会显示成灰色，看上去像被禁用了。
///
/// 审批面板尤其不能这样：用户看到两个灰按钮的第一反应是"点不了"，
/// 而那正是唯一需要他立刻决策的地方。所以外观必须完全由我们自己控制。
public struct IslandButtonStyle: ButtonStyle {
    public enum Emphasis { case prominent, secondary }

    let emphasis: Emphasis
    let tint: Color
    var width: CGFloat?
    var height: CGFloat = 30

    @Environment(\.isEnabled) private var isEnabled

    public init(
        emphasis: Emphasis = .secondary,
        tint: Color = IslandTheme.busy,
        width: CGFloat? = nil,
        height: CGFloat = 30
    ) {
        self.emphasis = emphasis
        self.tint = tint
        self.width = width
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IslandTheme.label(12, .semibold))
            .foregroundStyle(foreground)
            .frame(width: width, height: height)
            .background(background(pressed: configuration.isPressed))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch emphasis {
        // 实心按钮上用黑字：状态色都是高亮度的琥珀/蓝/绿，白字在上面对比度不够。
        case .prominent: return .black
        case .secondary: return .white.opacity(0.92)
        }
    }

    private func background(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack {
            switch emphasis {
            case .prominent:
                shape.fill(tint.opacity(pressed ? 0.78 : 1))
            case .secondary:
                shape.fill(.white.opacity(pressed ? 0.20 : 0.12))
                shape.stroke(.white.opacity(0.16), lineWidth: 1)
            }
        }
    }
}

/// 状态点。
///
/// **形状是第二编码通道**，不只是颜色：6 pt 尺度下空心 vs 实心的区分度
/// 强过任何颜色差，色觉障碍用户也能分辨。
/// - busy：实心圆角方
/// - waiting：实心圆 + 外环（最显眼）
/// - shell：实心硬方（圆角更小，视觉上更"硬"）
/// - idle：空心
public struct StatusDot: View {
    public let status: SessionStatus
    public let size: CGFloat

    public init(status: SessionStatus, size: CGFloat = 6) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        let color = IslandTheme.color(for: status)
        Group {
            switch status {
            case .waiting:
                Circle()
                    .fill(color)
                    .frame(width: size * 0.7, height: size * 0.7)
                    .overlay(
                        Circle()
                            .stroke(color.opacity(0.85), lineWidth: 1)
                            .frame(width: size, height: size)
                    )
            case .busy:
                RoundedRectangle(cornerRadius: size * 0.33, style: .continuous)
                    .fill(color)
                    .frame(width: size, height: size)
            case .shell:
                RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                    .fill(color)
                    .frame(width: size, height: size)
            case .idle, .unknown:
                // 空心是 idle 的形状编码。描边要够亮才能在 6pt 尺度下被看见，
                // 但整体透明度压低，保证它不和活跃状态抢注意力。
                RoundedRectangle(cornerRadius: size * 0.33, style: .continuous)
                    .stroke(color.opacity(0.6), lineWidth: 1.2)
                    .frame(width: size - 0.6, height: size - 0.6)
            }
        }
        .frame(width: size, height: size)
    }
}
