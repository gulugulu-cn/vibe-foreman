import AppKit
import SwiftUI

/// 灵动岛的背景材质。
///
/// ## 为什么不用 Liquid Glass
///
/// 这是一个**刻意放弃苹果官方 `.glassEffect` API** 的决定，理由是一条物理约束：
/// **岛的上半截必须和刘海严丝合缝，而刘海恒为纯黑。**
///
/// Liquid Glass 的设计目标是"盖在任何东西上，上面的内容都可读"，
/// 所以它会**跟着背景亮度双向补偿** —— 背景亮它变亮，背景暗它**也**变亮。
/// 实测（`.clear` + 黑 tint）：
///
/// | 背景 | 玻璃输出 | 压 0.72 黑罩之后 | 刘海 |
/// |---|---|---|---|
/// | 白底 Finder | ≈ 1.0 | 0.28（中灰） | 0.0 |
/// | 纯黑终端 | ≈ 0.45 | 0.13 | 0.0 |
///
/// 白底下要压到刘海那个黑需要 scrim ≈ 0.94，那时候"玻璃"已经完全不存在了。
/// 换句话说，**"任何背景下都贴合刘海" 和 "自适应玻璃" 在物理上互斥**，
/// 参数怎么调都不可能同时成立。用户选了前者。
///
/// ## 用什么代替
///
/// `NSVisualEffectView` + **强制暗色外观**。它做的是背景模糊 + 固定的暗色染色，
/// 不做那套亮度补偿，所以无论背后是什么，输出都稳定落在暗部。
///
/// 玻璃感并没有丢，只是换了来源：
/// - **背景模糊**由这一层提供（背后的形状会柔和地透出来）；
/// - **边缘高光**（`IslandTheme.edgeHighlight`）—— 真实玻璃的边缘因折射比中间亮，
///   这是"看起来像玻璃"最关键的一笔；
/// - **轻微透光**——完全不透就成了塑料。
///
/// 这正是真实刘海周围那块材质的样子：一块黑玻璃，而不是一块会变色的果冻。
struct IslandBackdrop: NSViewRepresentable {

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // .hudWindow 在暗色外观下是最接近"黑玻璃"的系统材质：
        // 比 .popover / .menu 暗得多，而且不带那层浅色底。
        view.material = .hudWindow
        // .behindWindow 才能采样到**窗口后面**的桌面/别的 app。
        // .withinWindow 只会采样本窗口内的内容，对一个全透明的 panel 等于什么都没有。
        view.blendingMode = .behindWindow
        // app 是 .accessory 且从不激活，用 .followsWindowActiveState 的话
        // 材质会长期停在"非活跃"的淡化状态。必须钉死 .active。
        view.state = .active
        // 强制暗色：不跟随系统浅色/深色。刘海在浅色模式下也是纯黑。
        view.appearance = NSAppearance(named: .darkAqua)
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // 外观和材质都是常量，没有需要随状态更新的东西。
        // 形状裁切交给 SwiftUI 侧的 .clipShape —— 让 NSView 自己做 mask
        // 会和 SwiftUI 的形变动画脱节。
    }
}
