import XCTest
@testable import HubUI

/// `.nudge` / `.answer` 两个新形态的尺寸回归。
///
/// 理由和 `IslandLayoutTests` 一样：SwiftUI 的布局裁切是**完全静默**的失败。
/// 悬停态那次算下来 113.5pt 塞进 96pt 的容器，外面套着 clipShape，
/// 直接被吃掉 17.5pt —— 没有报错、没有警告，只有用户看到"信息显示不全"。
final class NudgeLayoutTests: XCTestCase {

    private let notched = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        notchWidth: 185,
        notchHeight: 32
    )

    private let external = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        notchWidth: 0,
        notchHeight: 0
    )

    // MARK: - nudge

    func testNudgeBodyFitsItsContent() {
        for count in [1, 2, 3, 6, 9] {
            for geo in [notched, external] {
                let metrics = IslandMetrics.metrics(
                    for: .nudge, geometry: geo, sessionCount: count
                )
                XCTAssertGreaterThanOrEqual(
                    metrics.bodyHeight,
                    IslandMetrics.nudgeContentHeight,
                    "nudge 容器装不下内容（\(count) 个）—— 会被 clipShape 静默裁掉"
                )
                XCTAssertGreaterThanOrEqual(
                    metrics.bodyWidth,
                    IslandMetrics.nudgeRowWidth(count: count),
                    "nudge 宽度装不下小人排（\(count) 个）"
                )
            }
        }
    }

    /// 高度必须**恒定**：小人数量变了岛不该忽高忽低。
    /// 提醒是连着弹好几轮的，每轮高度不同会让人以为出了别的事。
    func testNudgeHeightIsIndependentOfCount() {
        let heights = Set(
            [1, 2, 3, 6, 9].map {
                IslandMetrics.metrics(for: .nudge, geometry: notched, sessionCount: $0)
                    .bodyHeight
            }
        )
        XCTAssertEqual(heights.count, 1, "nudge 高度不该随会话数变化")
    }

    /// 宽度要跟着数量走，但**有上下限**。
    /// 只有 1 个时不能宽得中间一大片空（会被读成加载失败），
    /// 9 个时也不能横跨整个屏幕。
    func testNudgeWidthGrowsWithinBounds() {
        let one = IslandMetrics.nudgeWidth(count: 1)
        let six = IslandMetrics.nudgeWidth(count: 6)
        XCTAssertLessThan(one, six, "宽度应随数量增长")
        XCTAssertGreaterThanOrEqual(one, 264, "太窄放不下标题行")
        XCTAssertLessThanOrEqual(six, 520, "太宽会横跨屏幕")
    }

    /// 超过上限的会话不画，靠标题上的 "+N" 交代 —— 但**宽度不能继续涨**。
    func testNudgeWidthSaturatesAtSpriteLimit() {
        let atLimit = IslandMetrics.nudgeWidth(count: IslandMetrics.nudgeSpriteLimit)
        let beyond = IslandMetrics.nudgeWidth(count: IslandMetrics.nudgeSpriteLimit + 10)
        XCTAssertEqual(atLimit, beyond)
    }

    /// 一格的高度必须容得下"图标 + 小人（含抬升）+ 名字"三段。
    /// 少算任何一段都会在 clipShape 里被无声吃掉。
    func testNudgeCellCoversAllThreeRows() {
        let needed = IslandMetrics.nudgeIconHeight
            + IslandMetrics.nudgeSpriteSide + IslandMetrics.nudgeLift
            + IslandMetrics.nudgeNameHeight
        XCTAssertGreaterThanOrEqual(IslandMetrics.nudgeCellHeight, needed)
    }

    // MARK: - answer

    func testAnswerBodyFitsItsContent() {
        for geo in [notched, external] {
            let metrics = IslandMetrics.metrics(for: .answer, geometry: geo)
            XCTAssertGreaterThanOrEqual(
                metrics.bodyHeight,
                IslandMetrics.answerContentHeight,
                "answer 容器装不下内容"
            )
        }
    }

    /// **提问态和发送预览态必须一样高。**
    ///
    /// 不一样的话，点一下快捷回答岛会跳一下 —— 而这一跳恰好发生在用户
    /// 正要去点"确认发送"的时候，按钮会在指针底下移位。
    /// 这里断言两态各自需要的高度都被同一个 `answerContentHeight` 覆盖。
    func testAnswerHeightCoversBothPhases() {
        let asking = IslandMetrics.answerVerticalInset * 2
            + IslandMetrics.answerHeaderHeight + IslandMetrics.answerGap
            + IslandMetrics.answerQuestionHeight + IslandMetrics.answerGap
            + IslandMetrics.answerButtonsHeight

        let confirming = IslandMetrics.answerVerticalInset * 2
            + IslandMetrics.answerHeaderHeight + IslandMetrics.answerGap
            + IslandMetrics.answerPreviewHeight + IslandMetrics.answerGap
            + IslandMetrics.answerButtonsHeight

        XCTAssertGreaterThanOrEqual(IslandMetrics.answerContentHeight, asking)
        XCTAssertGreaterThanOrEqual(IslandMetrics.answerContentHeight, confirming)
    }

    // MARK: - 形态完整性

    /// 新增形态时最容易漏掉的是几何和 scrim 的 switch 分支。
    /// 前者漏了编译不过，后者漏了也编译不过 —— 但两者都可能被填成占位值。
    /// 这里断言每个形态都有非零的尺寸。
    func testEveryStateHasUsableMetrics() {
        let states: [IslandState] = [
            .rest, .hover, .expanded, .intrusion, .approval, .nudge, .answer,
        ]
        for state in states {
            for geo in [notched, external] {
                let metrics = IslandMetrics.metrics(
                    for: state, geometry: geo, sessionCount: 3
                )
                XCTAssertGreaterThan(metrics.bodyWidth, 0, "\(state) 宽度为 0")
                XCTAssertGreaterThan(metrics.bodyHeight, 0, "\(state) 高度为 0")
                XCTAssertLessThanOrEqual(
                    metrics.bodyWidth, IslandMetrics.panelSize.width,
                    "\(state) 比窗口还宽，会被窗口裁掉"
                )
                XCTAssertLessThanOrEqual(
                    metrics.bodyHeight, IslandMetrics.panelSize.height,
                    "\(state) 比窗口还高"
                )
            }
        }
    }
}
