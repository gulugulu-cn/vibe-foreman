import HubCore
import HubProbe
import SwiftUI

/// 滞留提醒态：卡住的会话的小人从刘海下沿**弹出来排开**。
///
/// 为什么是小人而不是一行文字（用户自己提的方案，也确实更好）：
/// 折叠态的跑马灯只能塞下几个字，而"哪几个卡住了"本质是个**并列**的信息。
/// 小人排开一眼就能数出有几个、分别是什么状态，还能直接点。
/// 文字要表达同样的信息得滚三遍。
///
/// 复用 `SpriteRow`（单 Canvas 画 N 个小人 + 上面叠一层透明命中格），
/// 所以"一个时钟画全部小人"的能耗设计和逐个小人的悬停/点击都是现成的。
struct NudgeContent: View {

    let findings: [StallFinding]
    let store: SessionStore
    let model: IslandModel
    /// 点某个小人。带上 finding 是因为调用方要据此决定是跳转还是进应答态。
    let onPick: (StallFinding) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false

    private var shown: [StallFinding] {
        Array(findings.prefix(IslandMetrics.nudgeSpriteLimit))
    }

    private var sessions: [AgentSession] {
        shown.compactMap { finding in
            store.sessions.first { $0.sessionId == finding.sessionId }
        }
    }

    private var side: CGFloat { IslandMetrics.nudgeSpriteSide }
    private var spacing: CGFloat { IslandMetrics.nudgeSpriteSpacing }

    var body: some View {
        VStack(spacing: IslandMetrics.nudgeGap) {
            header
            grid
        }
        .padding(.vertical, IslandMetrics.nudgeVerticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else { popped = true; return }
            // 逐个弹出：靠每个小人自己的 delay 错开，见 offset(for:)。
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { popped = true }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text(headline)
                .font(IslandTheme.label(11, .semibold))
                .foregroundStyle(.white.opacity(0.9))
                // 会话名可以很长（`product-collab-optimizations` 有 28 个字符），
                // 不截断会把标题行撑出岛外。截断优于为最坏情况留宽度 ——
                // 名字在下面每个小人底下还会再出现一次。
                .lineLimit(1)
                .truncationMode(.middle)
            if findings.count > shown.count {
                Text("+\(findings.count - shown.count)")
                    .font(IslandTheme.label(9, .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(height: IslandMetrics.nudgeHeaderHeight)
    }

    /// 标题按**最高优先级**的那一条措辞，不做泛泛的"有 N 个会话需要处理"。
    /// 断线和待验收的紧迫程度差得远，混成一句话等于什么都没说。
    private var headline: String {
        guard let top = findings.first else { return "" }
        if findings.count == 1 {
            let name = store.sessions
                .first { $0.sessionId == top.sessionId }?
                .name ?? top.sessionId
            return "\(name) \(top.reason.shortLabel)"
        }
        return "\(findings.count) 个会话卡着 · 最急：\(top.reason.shortLabel)"
    }

    private var grid: some View {
        ZStack(alignment: .topLeading) {
            decoration
            hitGrid
        }
        .frame(
            width: IslandMetrics.nudgeRowWidth(count: shown.count),
            height: IslandMetrics.nudgeCellHeight
        )
    }

    /// 装饰层：图标 + 小人 + 名字。**完全不参与命中测试。**
    ///
    /// 和 `HoverContent` 里同样的分层理由：这层带弹出动画和阴影，
    /// 会被合成成离屏层进而吃掉点击。装饰归装饰、命中归命中。
    private var decoration: some View {
        HStack(spacing: spacing) {
            ForEach(Array(shown.enumerated()), id: \.element.sessionId) { index, finding in
                VStack(spacing: 0) {
                    Text(finding.reason.symbol)
                        .font(.system(size: 10))
                        .frame(height: IslandMetrics.nudgeIconHeight)

                    sprite(for: finding)
                        .frame(
                            width: side,
                            height: side + IslandMetrics.nudgeLift
                        )

                    Text(shortName(for: finding))
                        .font(IslandTheme.label(9, .medium))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                        .frame(height: IslandMetrics.nudgeNameHeight)
                }
                .frame(width: side)
                .offset(y: offset(for: index))
                .opacity(popped ? 1 : 0)
            }
        }
        .frame(height: IslandMetrics.nudgeCellHeight)
        .allowsHitTesting(false)
    }

    /// 从刘海里"被甩出来"的位移。第 i 个晚 60ms —— 一起弹是一整块在动，
    /// 错开才读得出"一个一个冒出来"。
    private func offset(for index: Int) -> CGFloat {
        guard !popped else { return 0 }
        return -(IslandMetrics.nudgeCellHeight + CGFloat(index) * 4)
    }

    @ViewBuilder
    private func sprite(for finding: StallFinding) -> some View {
        if let session = store.sessions.first(where: { $0.sessionId == finding.sessionId }) {
            SpriteRow(
                sessions: [session],
                pixelSize: 2,
                gridSize: 16,
                spacing: 0,
                useMicroArt: false,
                supportsLift: true,
                liftedSessionId: model.hoveredSessionId
            )
        } else {
            Color.clear
        }
    }

    private func shortName(for finding: StallFinding) -> String {
        let raw = store.sessions
            .first { $0.sessionId == finding.sessionId }?
            .name ?? finding.sessionId
        // 8 个字是 32pt 宽度下 9pt 字能放下的极限，超了 lineLimit 会截成"…"，
        // 而截在词中间读起来像乱码。这里主动按段截，保留最后一段（通常最有辨识度）。
        guard raw.count > 8 else { return raw }
        let segments = raw.split(separator: "-")
        if let last = segments.last, last.count <= 8, segments.count > 1 {
            return String(last)
        }
        return String(raw.prefix(7)) + "…"
    }

    /// 命中层：只有 `Color.clear`，格子按 `小人宽 + 间距`**连续平铺**。
    /// 间距如果不属于任何一格就是死区 —— 悬停态踩过这个坑。
    private var hitGrid: some View {
        HStack(spacing: 0) {
            ForEach(shown, id: \.sessionId) { finding in
                Color.clear
                    .frame(
                        width: side + spacing,
                        height: IslandMetrics.nudgeCellHeight
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            model.hoveredSessionId = finding.sessionId
                        } else if model.hoveredSessionId == finding.sessionId {
                            model.hoveredSessionId = nil
                        }
                    }
                    .onTapGesture { onPick(finding) }
                    .help(detail(for: finding))
            }
        }
        .padding(.horizontal, -spacing / 2)
        .frame(height: IslandMetrics.nudgeCellHeight)
    }

    private func detail(for finding: StallFinding) -> String {
        switch finding.reason {
        case .interrupted(let text): return "连接中断：\(text)"
        case .askedQuestion(let q): return q
        case .awaitingDecision(let why): return why ?? "等你授权"
        case .unfinishedTasks(_, _, let next):
            return next.map { "还差：\($0)" } ?? "还有未完成的任务"
        case .finishedAwaitingReview(let summary, _):
            return summary ?? "完成了一轮，等你验收"
        }
    }
}
