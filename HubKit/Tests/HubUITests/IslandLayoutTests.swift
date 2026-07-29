import XCTest
@testable import HubUI

/// 形态尺寸回归。
///
/// 存在的理由是一个真实事故：悬停态内容算下来要 113.5pt，而容器给的是 96pt，
/// 外面还套着 clipShape —— 于是被**静默裁掉** 17.5pt。没有报错、没有警告，
/// 只有用户看到"信息显示不全"。
///
/// 布局裁切在 SwiftUI 里是完全静默的失败，只能靠这种算术断言挡住。
final class IslandLayoutTests: XCTestCase {

    /// 本机实测的内建屏几何（16" M4 Max，默认缩放）。
    private let notched = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        notchWidth: 185,
        notchHeight: 32
    )

    /// 外接屏：无刘海。
    private let external = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        notchWidth: 0,
        notchHeight: 0
    )

    // MARK: - 内容必须放得下

    func testHoverBodyFitsItsContent() {
        for count in [0, 1, 3, 9, 20] {
            for geo in [notched, external] {
                let metrics = IslandMetrics.metrics(
                    for: .hover, geometry: geo, sessionCount: count
                )
                XCTAssertGreaterThanOrEqual(
                    metrics.bodyHeight,
                    IslandMetrics.hoverContentHeight,
                    "悬停态容器装不下内容（\(count) 个会话）—— 会被 clipShape 静默裁掉"
                )
                XCTAssertGreaterThanOrEqual(
                    metrics.bodyWidth,
                    IslandMetrics.hoverScreenSize(sessionCount: count).width,
                    "悬停态宽度装不下小人排（\(count) 个会话）"
                )
            }
        }
    }

    func testExpandedBodyFitsHeaderAndDetailCard() {
        for geo in [notched, external] {
            for count in [1, 4, 9, 30] {
                let metrics = IslandMetrics.metrics(
                    for: .expanded, geometry: geo, sessionCount: count
                )
                // header + 分栏 + 详情卡 + 至少一行列表，否则展开的意义就没了。
                let minimum = IslandMetrics.expandedHeaderHeight
                    + IslandMetrics.expandedTabHeight
                    + IslandMetrics.expandedDetailHeight
                    + IslandMetrics.expandedRowHeight
                XCTAssertGreaterThanOrEqual(metrics.bodyHeight, minimum)
                XCTAssertLessThanOrEqual(
                    metrics.bodyHeight, IslandMetrics.expandedMaxHeight
                )
            }
        }
    }

    /// 项目栏至少要能放下几行。
    ///
    /// 展开态的高度是按**会话数**算的，但「项目」栏里通常有二十来个项目 ——
    /// 会话很少时（比如只有 1 个）高度会收得很紧，别把项目列表挤成一条缝。
    func testProjectTabHasUsableHeightEvenWithOneSession() {
        let metrics = IslandMetrics.metrics(
            for: .expanded, geometry: notched, sessionCount: 1
        )
        let chrome = IslandMetrics.expandedHeaderHeight + IslandMetrics.expandedTabHeight
        let listRoom = metrics.bodyHeight - chrome
        XCTAssertGreaterThanOrEqual(
            listRoom, IslandMetrics.expandedProjectRowHeight * 4,
            "只有 1 个会话时，项目栏连 4 行都放不下"
        )
    }

    /// 展开态高度跟着会话数走：4 个会话时不该挂着一大片空玻璃。
    func testExpandedHeightAdaptsToSessionCount() {
        let few = IslandMetrics.expandedHeight(sessionCount: 3)
        let many = IslandMetrics.expandedHeight(sessionCount: 9)
        XCTAssertLessThan(few, many)
        XCTAssertEqual(
            IslandMetrics.expandedHeight(sessionCount: 200),
            IslandMetrics.expandedMaxHeight
        )
        // 一个会话都没有时也要能立住，不能算出负数或 0。
        XCTAssertGreaterThan(IslandMetrics.expandedHeight(sessionCount: 0), 0)
    }

    func testApprovalBodyFitsItsContent() {
        for geo in [notched, external] {
            let metrics = IslandMetrics.metrics(for: .approval, geometry: geo)
            XCTAssertGreaterThanOrEqual(
                metrics.bodyHeight, IslandMetrics.approvalContentHeight
            )
        }
    }

    /// 所有形态都不能超出固定的窗口尺寸 —— 窗口不会跟着变大，超出部分是画不出来的。
    func testEveryStateFitsInsideThePanel() {
        let states: [IslandState] = [.rest, .hover, .expanded, .intrusion, .approval]
        for state in states {
            for geo in [notched, external] {
                let metrics = IslandMetrics.metrics(
                    for: state, geometry: geo, sessionCount: 9
                )
                XCTAssertLessThanOrEqual(
                    metrics.bodyWidth, IslandMetrics.panelSize.width,
                    "\(state) 比窗口还宽"
                )
                XCTAssertLessThanOrEqual(
                    metrics.bodyHeight + geo.notchHeight, IslandMetrics.panelSize.height,
                    "\(state) 比窗口还高"
                )
            }
        }
    }

    // MARK: - 折叠态不能压住菜单栏

    /// 折叠态上半段的宽度必须**严格等于**刘海宽。
    ///
    /// 多出一点点就会压在菜单栏图标上，把输入法、电量的点击吃掉 ——
    /// 这是"岛把系统搞坏了"最容易发生的方式。
    func testRestShapeDoesNotCoverTheMenuBar() {
        let metrics = IslandMetrics.metrics(for: .rest, geometry: notched)
        let shape = IslandShape(
            notchWidth: notched.notchWidth,
            notchHeight: notched.notchHeight,
            bodyWidth: metrics.bodyWidth,
            bodyHeight: metrics.bodyHeight,
            bottomRadius: metrics.bottomRadius
        )
        let rect = CGRect(origin: .zero, size: IslandMetrics.panelSize)
        let path = shape.path(in: rect).cgPath
        let centerX = rect.midX

        // 刘海高度之内、刘海边缘之外的点，全都必须落在形状外面。
        for y in stride(from: CGFloat(1), through: notched.notchHeight - 1, by: 4) {
            let justOutside = centerX + notched.notchWidth / 2 + 2
            XCTAssertFalse(
                path.contains(CGPoint(x: justOutside, y: y)),
                "折叠态在 y=\(y) 处越过了刘海右沿，会吃掉菜单栏点击"
            )
            XCTAssertTrue(
                path.contains(CGPoint(x: centerX, y: y)),
                "折叠态在 y=\(y) 处没有覆盖刘海中心"
            )
        }
    }

    /// 折叠态确实比刘海宽（"液体挤出"），但只在刘海下沿之后。
    func testRestFlaresOnlyBelowTheNotch() {
        let metrics = IslandMetrics.metrics(for: .rest, geometry: notched)
        XCTAssertGreaterThan(metrics.bodyWidth, notched.notchWidth)

        let shape = IslandShape(
            notchWidth: notched.notchWidth,
            notchHeight: notched.notchHeight,
            bodyWidth: metrics.bodyWidth,
            bodyHeight: metrics.bodyHeight,
            bottomRadius: metrics.bottomRadius
        )
        let rect = CGRect(origin: .zero, size: IslandMetrics.panelSize)
        let path = shape.path(in: rect).cgPath
        let centerX = rect.midX
        let belowNotch = notched.notchHeight + metrics.bodyHeight / 2

        XCTAssertTrue(
            path.contains(CGPoint(
                x: centerX + notched.notchWidth / 2 + 2, y: belowNotch
            )),
            "刘海下方应该已经扩张开了"
        )
    }

    // MARK: - 无刘海走胶囊

    func testExternalScreenUsesPillNotHalfLip() {
        XCTAssertFalse(external.hasNotch)
        let metrics = IslandMetrics.metrics(for: .rest, geometry: external)
        let shape = IslandShape(
            notchWidth: external.notchWidth,
            notchHeight: external.notchHeight,
            bodyWidth: metrics.bodyWidth,
            bodyHeight: metrics.bodyHeight,
            bottomRadius: metrics.bottomRadius
        )
        let rect = CGRect(origin: .zero, size: IslandMetrics.panelSize)
        let path = shape.path(in: rect).cgPath

        // 胶囊距顶悬浮，所以 y=0 那一行不该有东西。
        XCTAssertFalse(path.contains(CGPoint(x: rect.midX, y: 0)))
        XCTAssertTrue(
            path.contains(CGPoint(x: rect.midX, y: 8 + metrics.bodyHeight / 2))
        )
    }

    // MARK: - 悬停宽度自适应

    func testHoverWidthGrowsWithSessionCountAndIsBounded() {
        let one = IslandMetrics.hoverWidth(sessionCount: 1)
        let five = IslandMetrics.hoverWidth(sessionCount: 5)
        let nine = IslandMetrics.hoverWidth(sessionCount: 9)
        let absurd = IslandMetrics.hoverWidth(sessionCount: 400)

        XCTAssertLessThanOrEqual(one, five)
        XCTAssertLessThan(five, nine)
        // 超过上限的会话数不该把岛撑爆 —— 多出来的在展开态的列表里看。
        XCTAssertEqual(nine, absurd)
        XCTAssertLessThanOrEqual(absurd, 520)
        XCTAssertGreaterThanOrEqual(one, 264)
    }

    /// 会话数为 0 时也要有个合理的宽度，不能算出 0 或负数。
    func testHoverWidthHandlesEmptyStore() {
        XCTAssertGreaterThan(IslandMetrics.hoverWidth(sessionCount: 0), 0)
        XCTAssertGreaterThan(IslandMetrics.hoverRowWidth(sessionCount: 0), 0)
    }
}
