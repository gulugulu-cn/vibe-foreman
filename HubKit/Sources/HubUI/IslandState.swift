import SwiftUI

/// 岛的形态。
///
/// 先落地三个基础态；`intrusion`（事件闯入）和 `approval`（审批）在后续阶段接入，
/// 它们复用同一套几何与动画机制，只是内容和触发方式不同。
public enum IslandState: Equatable, Sendable {
    /// 折叠常驻。贴着刘海只露一条"下唇"。
    case rest
    /// 悬停摘要。露出像素小人排和一行统计。
    case hover
    /// 完全展开。会话列表 + 操作。
    case expanded
    /// 事件闯入。某会话完成或需要输入时主动膨胀提示，几秒后回落。
    case intrusion
    /// 审批。高风险操作拦截，等用户决策。**不会自动回落。**
    case approval
    /// 滞留提醒。**聚合**多个卡住的会话，小人从刘海弹出来排开，每个可点。
    ///
    /// 和 `intrusion` 刻意分开，语义不同：`intrusion` 是"某件事刚发生"，
    /// 单会话、两秒划过；`nudge` 是"你有 N 件事卡着"，停得更久、可交互。
    case nudge
    /// 岛上应答。显示 AI 的问题和快捷回答，**不会自动回落**。
    case answer
}

/// 某个形态在某块屏幕上的具体尺寸。
///
/// 全部由 `NotchGeometry` 推导，没有任何写死的绝对坐标 —— 换机器、改缩放、
/// 插拔外接屏都不需要动代码。
public struct IslandMetrics: Equatable, Sendable {
    public let bodyWidth: CGFloat
    public let bodyHeight: CGFloat
    public let bottomRadius: CGFloat

    /// 窗口固定尺寸。
    ///
    /// 窗口**永远是这么大**，形态切换只改 SwiftUI 内部布局，绝不调 `setFrame`：
    /// 窗口 frame 动画走 CoreAnimation 隐式事务，和 SwiftUI 的 spring 不同步，
    /// 展开时会看到内容被裁掉一两帧。
    public static let panelSize = CGSize(width: 640, height: 720)

    /// 折叠态主体比刘海每侧宽出的量。这点溢出正是"液体挤出"的形态语言。
    private static let restBleedPerSide: CGFloat = 8

    // MARK: - 悬停态几何
    //
    // 这几个常量同时被 `IslandMetrics`（决定岛多大）和 `HoverContent`（决定画多大）读，
    // **必须共用同一份**。以前两边各写各的，结果内容算出来 113.5pt 却塞进 96pt 的容器，
    // 外面还套着 clipShape，直接被裁掉 17.5pt —— 这就是用户看到的"信息显示不全"。

    /// 悬停态一个小人占的边长（16×16 art × 2pt）。
    public static let hoverSpriteSide: CGFloat = 32
    /// 小人之间的间距。
    public static let hoverSpriteSpacing: CGFloat = 8
    /// 悬停态最多摆几个小人。超出的部分在展开态的列表里看。
    public static let hoverSpriteLimit = 9
    /// "屏"的内边距（必须和 `SpriteScreen` 的 padding 一致）。
    public static let hoverScreenPadding = CGSize(width: 8, height: 4)
    /// 被指到的小人抬起的高度。Canvas 顶部要预留这么多余量，否则会被裁掉。
    public static let hoverLift: CGFloat = 2
    /// 小人下方那条状态色横条的高度 + 它与小人之间的间距。
    public static let hoverStatusBarBlock: CGFloat = 7
    /// 岛边缘到"屏"的留白（左右各一份）。
    public static let hoverSideInset: CGFloat = 20
    /// 名字行（会话名 13pt + 副行 11pt + 行距）。
    public static let hoverCaptionHeight: CGFloat = 32
    /// 内容区上下留白。
    public static let hoverVerticalInset: CGFloat = 10
    /// "屏"与名字行之间的间距。
    public static let hoverGap: CGFloat = 8

    /// 悬停态摆 n 个小人时，那一排的实际宽度。
    public static func hoverRowWidth(sessionCount: Int) -> CGFloat {
        let n = max(1, min(sessionCount, hoverSpriteLimit))
        return CGFloat(n) * hoverSpriteSide + CGFloat(n - 1) * hoverSpriteSpacing
    }

    /// 悬停态"屏"的整体尺寸。
    public static func hoverScreenSize(sessionCount: Int) -> CGSize {
        CGSize(
            width: hoverRowWidth(sessionCount: sessionCount) + hoverScreenPadding.width * 2,
            height: hoverSpriteSide + hoverLift + hoverStatusBarBlock
                + hoverScreenPadding.height * 2
        )
    }

    /// 悬停态内容的最小高度。岛的 `bodyHeight` 不得小于它。
    public static var hoverContentHeight: CGFloat {
        hoverVerticalInset * 2
            + hoverScreenSize(sessionCount: 1).height
            + hoverGap
            + hoverCaptionHeight
    }

    /// 悬停态宽度**跟着会话数走**。
    ///
    /// 写死 380 的问题：只有 3 个会话时中间空一大块，会读成"加载失败"；
    /// 而 9 个会话时又刚好卡满没有呼吸感。下限保证名字行有地方放。
    public static func hoverWidth(sessionCount: Int) -> CGFloat {
        let ideal = hoverScreenSize(sessionCount: sessionCount).width + hoverSideInset * 2
        return min(max(ideal, 264), 520)
    }

    // MARK: - 滞留提醒态几何
    //
    // 和悬停态一样，这些常量**同时被 IslandMetrics 和 NudgeContent 读**，
    // 必须共用同一份。两边各写各的那次，内容算出 113.5pt 塞进 96pt 的容器，
    // 外面还套着 clipShape，直接被裁掉 17.5pt —— 就是用户看到的"信息显示不全"。

    /// 一个小人占的边长（16×16 art × 2pt）。
    public static let nudgeSpriteSide: CGFloat = 32
    public static let nudgeSpriteSpacing: CGFloat = 12
    /// 最多摆几个。再多就该去展开态看列表了。
    public static let nudgeSpriteLimit = 6
    /// 小人被指到时抬起的高度，Canvas 顶部要留出来。
    public static let nudgeLift: CGFloat = 2
    /// 小人上方的原因图标行（⚡ / ❓ / ⚠ / ▸ / ✓）。
    public static let nudgeIconHeight: CGFloat = 14
    /// 小人下方的会话名行（9pt 字）。
    public static let nudgeNameHeight: CGFloat = 12
    /// 顶部那行标题（"2 个会话在等你"）。
    public static let nudgeHeaderHeight: CGFloat = 16
    public static let nudgeGap: CGFloat = 4
    public static let nudgeVerticalInset: CGFloat = 10
    public static let nudgeSideInset: CGFloat = 22

    /// 一格的高度：图标 + 小人（含抬升）+ 名字。整格都可点。
    public static var nudgeCellHeight: CGFloat {
        nudgeIconHeight + nudgeSpriteSide + nudgeLift + nudgeNameHeight + nudgeGap * 2
    }

    public static var nudgeContentHeight: CGFloat {
        nudgeVerticalInset * 2 + nudgeHeaderHeight + nudgeGap + nudgeCellHeight
    }

    public static func nudgeRowWidth(count: Int) -> CGFloat {
        let n = max(1, min(count, nudgeSpriteLimit))
        return CGFloat(n) * nudgeSpriteSide + CGFloat(n - 1) * nudgeSpriteSpacing
    }

    public static func nudgeWidth(count: Int) -> CGFloat {
        let ideal = nudgeRowWidth(count: count) + nudgeSideInset * 2
        // 下限保证标题那行放得下（标题本身有 lineLimit(1) 兜底，
        // 所以不需要为最长的会话名留空间）；上限别横跨整个屏幕。
        //
        // 下限不能设太高：6 个小人也才 296pt，下限一旦到 300，
        // "宽度跟着数量走"就被压平成了固定宽度。
        return min(max(ideal, 264), 520)
    }

    // MARK: - 应答态几何

    public static let answerHeaderHeight: CGFloat = 20
    /// 问题正文最多三行 13pt。
    public static let answerQuestionHeight: CGFloat = 48
    /// 按钮行（含发送预览态的两个按钮）。
    public static let answerButtonsHeight: CGFloat = 28
    /// 发送预览里那条"将发送到 X：内容"。
    public static let answerPreviewHeight: CGFloat = 40
    public static let answerVerticalInset: CGFloat = 12
    public static let answerGap: CGFloat = 8

    /// **提问态和预览态取同一个高度。**
    ///
    /// 两态高度不同的话，点一下按钮岛会跳一下 —— 而这一跳发生在用户正要去点
    /// "确认发送"的时候，按钮会在指针底下移位。宁可有一点空白也不能让它跳。
    public static var answerContentHeight: CGFloat {
        let asking = answerHeaderHeight + answerGap + answerQuestionHeight
            + answerGap + answerButtonsHeight
        let confirming = answerHeaderHeight + answerGap + answerPreviewHeight
            + answerGap + answerButtonsHeight
        return answerVerticalInset * 2 + max(asking, confirming)
    }

    public static func metrics(
        for state: IslandState,
        geometry: NotchGeometry,
        sessionCount: Int = 0
    ) -> IslandMetrics {
        let hoverW = hoverWidth(sessionCount: sessionCount)
        let hoverH = hoverContentHeight

        if geometry.hasNotch {
            switch state {
            case .rest:
                return IslandMetrics(
                    bodyWidth: geometry.notchWidth + restBleedPerSide * 2,
                    bodyHeight: 14,
                    bottomRadius: 14
                )
            case .hover:
                return IslandMetrics(bodyWidth: hoverW, bodyHeight: hoverH, bottomRadius: 26)
            case .expanded:
                return IslandMetrics(
                    bodyWidth: 580,
                    bodyHeight: expandedHeight(sessionCount: sessionCount),
                    bottomRadius: 28
                )
            case .intrusion:
                return IslandMetrics(bodyWidth: 360, bodyHeight: 62, bottomRadius: 22)
            case .approval:
                return IslandMetrics(bodyWidth: 470, bodyHeight: 248, bottomRadius: 26)
            case .nudge:
                return IslandMetrics(
                    bodyWidth: nudgeWidth(count: sessionCount),
                    bodyHeight: nudgeContentHeight,
                    bottomRadius: 26
                )
            case .answer:
                return IslandMetrics(
                    bodyWidth: 460, bodyHeight: answerContentHeight, bottomRadius: 26
                )
            }
        } else {
            // 无刘海：折叠态是个独立胶囊，不是"半个下唇"。
            switch state {
            case .rest:
                return IslandMetrics(bodyWidth: 132, bodyHeight: 26, bottomRadius: 13)
            case .hover:
                return IslandMetrics(bodyWidth: hoverW, bodyHeight: hoverH, bottomRadius: 24)
            case .expanded:
                return IslandMetrics(
                    bodyWidth: 580,
                    bodyHeight: expandedHeight(sessionCount: sessionCount),
                    bottomRadius: 28
                )
            case .intrusion:
                return IslandMetrics(bodyWidth: 360, bodyHeight: 58, bottomRadius: 22)
            case .approval:
                return IslandMetrics(bodyWidth: 470, bodyHeight: 244, bottomRadius: 26)
            case .nudge:
                return IslandMetrics(
                    bodyWidth: nudgeWidth(count: sessionCount),
                    bodyHeight: nudgeContentHeight,
                    bottomRadius: 24
                )
            case .answer:
                return IslandMetrics(
                    bodyWidth: 460, bodyHeight: answerContentHeight, bottomRadius: 24
                )
            }
        }
    }

    // MARK: - 展开态几何

    /// 展开态各段高度。
    public static let expandedHeaderHeight: CGFloat = 44
    public static let expandedDetailHeight: CGFloat = 146
    public static let expandedRowHeight: CGFloat = 52
    /// 项目行比会话行矮：它只有名字 + 分支两行，没有小人和时间戳。
    /// 而项目通常有二十来个，行矮一点一屏能多看几个。
    public static let expandedProjectRowHeight: CGFloat = 40
    /// 会话 / 项目 切换栏。
    public static let expandedTabHeight: CGFloat = 30
    /// 展开态最高能长到多少（列表更长时内部滚动）。
    public static let expandedMaxHeight: CGFloat = 512

    /// 展开态高度**跟着会话数走**。
    ///
    /// 固定 512 的问题：只有 3、4 个会话时下面挂着一大片空玻璃，
    /// 读起来像"加载失败"或"内容被吞了"。列表长了再涨到上限并转为内部滚动。
    public static func expandedHeight(sessionCount: Int) -> CGFloat {
        let list = CGFloat(max(1, sessionCount)) * expandedRowHeight + 24
        let ideal = expandedHeaderHeight + expandedTabHeight
            + expandedDetailHeight + 8 + list
        return min(ideal, expandedMaxHeight)
    }

    /// 审批态内容的最小高度（header + 命令块 + 按钮 + 上下留白）。
    public static let approvalContentHeight: CGFloat = 48 + 84 + 44 + 24 + 20
}

/// 形态转场动画。
///
/// 参数不是随手填的：
/// - 进入 hover 几乎不回弹（`extraBounce` 极小），要跟手；
/// - 展开明显有分量感（`bouncy`），跨度越大越慢；
/// - 收回一律 `smooth`，干脆利落不留恋。
public enum IslandAnimation {
    public static func transition(
        from old: IslandState,
        to new: IslandState,
        reduceMotion: Bool
    ) -> Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.2)
        }
        switch (old, new) {
        case (.rest, .hover):
            return .snappy(duration: 0.30, extraBounce: 0.02)
        case (.hover, .rest):
            return .smooth(duration: 0.24)
        case (.hover, .expanded):
            return .bouncy(duration: 0.42, extraBounce: 0.12)
        case (.rest, .expanded):
            return .bouncy(duration: 0.46, extraBounce: 0.14)
        case (.expanded, _):
            return .smooth(duration: 0.28)
        case (_, .nudge):
            // 比 intrusion 更欠阻尼：它出场的前提是"你已经错过一次了"，
            // 那个回弹就是在拽注意力。小人从刘海里被"甩"出来的观感也靠它。
            return .spring(response: 0.34, dampingFraction: 0.58)
        case (.nudge, .answer):
            return .snappy(duration: 0.32, extraBounce: 0.05)
        case (.nudge, _):
            return .smooth(duration: 0.26)
        case (_, .answer):
            return .spring(response: 0.32, dampingFraction: 0.74)
        case (.answer, _):
            return .smooth(duration: 0.28)
        case (_, .intrusion):
            // 欠阻尼，回弹是为了吸引注意 —— 这是唯一一个主动打扰用户的形态。
            return .spring(response: 0.28, dampingFraction: 0.66)
        case (.intrusion, .approval):
            return .snappy(duration: 0.34, extraBounce: 0.06)
        case (.intrusion, _):
            return .easeOut(duration: 0.22)
        case (_, .approval):
            return .spring(response: 0.32, dampingFraction: 0.72)
        case (.approval, _):
            return .smooth(duration: 0.30)
        default:
            return .smooth(duration: 0.26)
        }
    }

    /// 内容淡入永远比形状晚 80 ms —— 形状先到位，内容再"浮现"。
    /// 这是 Dynamic Island 手感的核心，去掉它整个动效会显得廉价。
    public static func contentIn(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.16).delay(0.08)
    }

    /// 退出时反过来：内容先走，形状后收。
    public static func contentOut(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.1) : .easeIn(duration: 0.10)
    }
}
