import HubCore
import SwiftUI

/// 全局像素时钟。
///
/// **所有小人共用一个 `TimelineView`。** 每个小人一个时间源的话，N 个小人
/// 就是 N 个重绘源，开销线性放大，而且没法整体冻结。
///
/// `minimumInterval` 必须给：不给就跟着 display link 走，ProMotion 下是 120fps
/// 重绘 9 个 Canvas —— 真正的耗电来源不是绘制量，是**唤醒频率**。持续的高频
/// 唤醒会让 CPU 无法进入深度 idle，这才是常驻 app 掉电的原因。
struct SpriteClock<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isActive: Bool
    let paused: Bool
    @ViewBuilder let content: (Int) -> Content

    /// 主时钟 12fps。素材本身按 6fps / 4fps 设计，用 2–3 个 tick 一帧实现，
    /// 这样不同状态可以有不同节奏而共享同一个时间源。
    private var interval: TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 1.0 / 6 }
        return isActive ? 1.0 / 12 : 1.0 / 2
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: paused || reduceMotion)) { ctx in
            content(Int(ctx.date.timeIntervalSinceReferenceDate / interval))
        }
    }
}

/// 一排像素小人，全部画在**同一个 Canvas** 里。
///
/// 选 Canvas 而不是 SpriteKit 有个硬理由：`SpriteView` 是不透明的 Metal 合成层，
/// 放进 `.glassEffect` 的容器里，玻璃无法采样它下方的内容，会在小人区域出现
/// 一块方形的"玻璃断层"。那是调参解决不了的。
struct SpriteRow: View {
    let sessions: [AgentSession]
    /// 每个 art 像素占多少 pt。**必须是整数** —— 用 1.5 pt/px 会产生半像素，
    /// 边缘发灰，"像素风"立刻变成"低分辨率图片"。
    let pixelSize: CGFloat
    /// art 网格边长（16 或 8）。
    let gridSize: Int
    let spacing: CGFloat
    let useMicroArt: Bool

    /// 这一排是否支持"指到谁谁抬起来"。为 true 时顶部预留 `liftAmount` 的余量，
    /// 否则抬升会被 Canvas 的上边界裁掉。
    var supportsLift = false

    /// 被指到的那个会话。它的小人整体抬起 `liftAmount`，作为悬停反馈。
    ///
    /// 抬升做在 Canvas 内部而不是给每个小人套一个 SwiftUI 视图 ——
    /// 后者意味着 N 个 Canvas + N 个 TimelineView，正是这个类型要避免的。
    var liftedSessionId: String?

    private var liftAmount: CGFloat { supportsLift ? pixelSize : 0 }

    private var spriteSide: CGFloat { CGFloat(gridSize) * pixelSize }

    /// Canvas 的实际高度（含抬升余量）。
    var canvasHeight: CGFloat { spriteSide + liftAmount }

    private var totalWidth: CGFloat {
        guard !sessions.isEmpty else { return 0 }
        return CGFloat(sessions.count) * spriteSide
            + CGFloat(sessions.count - 1) * spacing
    }

    var body: some View {
        SpriteClock(
            isActive: sessions.contains { $0.status.isActive },
            paused: false
        ) { tick in
            canvas(tick: tick)
        }
        .frame(width: totalWidth, height: canvasHeight)
    }

    private func canvas(tick: Int) -> some View {
        ZStack {
            // 辉光：把同一张画模糊后用 plusLighter 叠一层。
            // 连续柔和的光晕在硬边像素和柔和玻璃之间架了一座桥，
            // 这是像素风能和 Liquid Glass 共处的第二个手段（第一个是那块"屏"）。
            painter(tick: tick)
                .blur(radius: pixelSize * 1.2)
                .opacity(0.42)
                .blendMode(.plusLighter)
            painter(tick: tick)
        }
        // 用 compositingGroup 而不是 drawingGroup：后者会建离屏 buffer，
        // 有可能打断下方 Liquid Glass 的背景采样链。
        .compositingGroup()
    }

    private func painter(tick: Int) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            for (index, session) in sessions.enumerated() {
                let originX = CGFloat(index) * (spriteSide + spacing)
                // 未抬起的小人落在预留余量之下；被指到的那个升到顶。
                let originY = session.sessionId == liftedSessionId ? 0 : liftAmount
                // 用**稳定的**哈希：Swift 的 `hashValue` 每次进程启动都加盐，
                // 那样同一个会话每次重开 app 都会换发色和衣服，"记住橙头发那个"
                // 这件事就不成立了。形象必须是会话的属性，不是本次运行的属性。
                let seed = SpriteSeed.stable(session.sessionId)
                let character = SpriteCharacter(seed: seed, status: session.status)
                let frame = useMicroArt
                    ? SpriteLibrary.micro(for: session.status, tick: tick, seed: seed)
                    : SpriteLibrary.frame(for: session.status, tick: tick, seed: seed)

                for run in frame.runs {
                    let rect = CGRect(
                        // 取整到整数 pt：任何半像素都会让边缘出现灰边。
                        x: (originX + CGFloat(run.x) * pixelSize).rounded(),
                        y: (originY + CGFloat(run.y) * pixelSize).rounded(),
                        width: CGFloat(run.width) * pixelSize,
                        height: pixelSize
                    )
                    context.fill(
                        Path(rect),
                        with: .color(run.ink.color(
                            character: character, status: session.status
                        ))
                    )
                }
            }
        }
        .frame(width: totalWidth, height: canvasHeight)
    }
}

/// 单个小人。
struct PixelSprite: View {
    let session: AgentSession
    let pixelSize: CGFloat
    let gridSize: Int
    let useMicroArt: Bool

    init(
        session: AgentSession,
        pixelSize: CGFloat = 2,
        gridSize: Int = 16,
        useMicroArt: Bool = false
    ) {
        self.session = session
        self.pixelSize = pixelSize
        self.gridSize = gridSize
        self.useMicroArt = useMicroArt
    }

    var body: some View {
        SpriteRow(
            sessions: [session],
            pixelSize: pixelSize,
            gridSize: gridSize,
            spacing: 0,
            useMicroArt: useMicroArt
        )
    }
}

/// 罩住小人的"显示屏"。
///
/// 这是调和像素风与 Liquid Glass 的**核心手段**，比辉光、调色板那些加起来都重要。
///
/// 矛盾是真实的：Liquid Glass 是连续、折射、无边界的；像素风是离散、硬边、有网格的。
/// 直接把 8-bit 小人贴在毛玻璃上，观感像"在 Vision Pro 上贴了张 FC 卡带贴纸"。
///
/// 解法不是让两者妥协，而是给它们一个**自洽的物质叙事**：玻璃是外壳/取景框，
/// 像素是被这块玻璃罩住的发光点阵屏。真实世界里这是成立的（老式设备的玻璃面板
/// 下面就是点阵屏），所以大脑接受。
struct SpriteScreen<Content: View>: View {
    var cornerRadius: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                // 比岛本身**亮**一点。
                //
                // 以前这里是近黑（0.03,0.04,0.06），而小人的描边也是近黑 ——
                // 描边完全溶进底板，人物之间、五官之间全糊在一起。
                // 现在角色是彩色的、描边是深色的，底板必须落在两者中间，
                // 这样描边才有得可读。视觉上它仍然是一块凹进去的点阵屏。
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.14, blue: 0.18).opacity(0.92))
                    .overlay {
                        // 内阴影：上暗下亮，模拟凹陷。
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        .black.opacity(0.55),
                                        .white.opacity(0.07),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                            .blur(radius: 0.6)
                    }
            }
    }
}
