import HubProjects
import XCTest
@testable import HubUI

/// 项目行的菜单内容。
///
/// 用户的原话：「不然每次要点击后面的按钮才能选择有点鸡肋」。修法是把菜单
/// 接到右键上，而右键、"…" 按钮、主窗口的 ▶ 按钮**必须是同一份内容** ——
/// 各写一遍必然漂移，实际上已经漂过一次：岛的菜单里有「接着上次」，
/// 主窗口的没有，同一个项目在两个界面上能做的事不一样，
/// 而用户没有任何线索知道为什么。
@MainActor
final class ProjectMenuTests: XCTestCase {

    private func items(
        isPinned: Bool = false, resumable: ClosedSession? = nil
    ) -> [RowMenu.Item?] {
        ProjectMenu.items(
            isPinned: isPinned, resumable: resumable,
            onLaunch: { _ in }, onTogglePin: {}
        )
    }

    private var titles: [String] {
        items().compactMap { $0?.title }
    }

    /// 每一种开法都要在。少一个的话，那个开法就只剩"没有入口"这一种状态。
    func testEveryLaunchModeIsPresent() {
        let titles = self.titles
        for mode in LaunchMode.allCases where mode != .resumeSession {
            XCTAssertTrue(titles.contains(mode.label), "菜单里少了「\(mode.label)」")
        }
    }

    /// **`.resumeSession` 不能出现在通用那一段。**
    ///
    /// 它要一个具体的 sessionId，而那个 id 只有「接着上次」那条知道。
    /// 放进来只会退化成 `claude --resume` 的交互列表 —— 那个列表里
    /// 全是一模一样的项目名，用户得人肉认。
    func testGenericSectionExcludesResumeSession() {
        XCTAssertFalse(titles.contains(LaunchMode.resumeSession.label))
    }

    /// 没东西可接时不该出现「接着上次」——一个点了什么都不会发生的菜单项
    /// 比没有这一项更糟。
    func testNoResumeEntryWhenNothingToResume() {
        XCTAssertFalse(titles.contains { $0.hasPrefix("接着上次") })
    }

    /// 有可接回的会话时，它**排第一**。关掉窗口后回来的人想接着往下走，
    /// 埋在「Claude Code」下面等于让他每次都重开一个新的。
    func testResumeEntryComesFirst() {
        let closed = ClosedSession(
            sessionId: "s1", name: "app-a1", cwd: "/x", endedAt: Date()
        )
        let first = items(resumable: closed).first??.title
        XCTAssertNotNil(first)
        XCTAssertTrue(
            first?.hasPrefix("接着上次") == true,
            "第一项应该是「接着上次」，实际是「\(first ?? "nil")」"
        )
    }

    /// 「接着上次」后面要有分隔线，否则它和普通开法糊成一片，
    /// 看不出这一条是不一样的东西。
    func testResumeEntryIsSeparatedFromTheRest() {
        let closed = ClosedSession(
            sessionId: "s1", name: "app-a1", cwd: "/x", endedAt: Date()
        )
        let list = items(resumable: closed)
        XCTAssertNil(list[1], "「接着上次」后面应该是分隔线")
    }

    /// 置顶项跟着当前状态换文案 —— 显示成「置顶」但实际是取消置顶，
    /// 用户点一次才知道。
    func testPinLabelReflectsCurrentState() {
        XCTAssertTrue(items(isPinned: false).compactMap { $0?.title }.contains("置顶"))
        XCTAssertTrue(items(isPinned: true).compactMap { $0?.title }.contains("取消置顶"))
    }

    /// 置顶排在最后，且前面有分隔线 —— 它不是"一种开法"。
    func testPinIsLastAndSeparated() {
        let list = items()
        XCTAssertEqual(list.last??.title, "置顶")
        XCTAssertNil(list[list.count - 2], "置顶前面应该是分隔线")
    }

    // MARK: - 共用密钥

    /// 项目没绑共用密钥时不该有这一项 —— 点了没反应的菜单项，
    /// 和「菜单坏了」在用户眼里是一回事。
    func testSecretPathItemIsAbsentWhenUnbound() {
        XCTAssertFalse(titles.contains("复制密钥路径"))
    }

    func testSecretPathItemAppearsWhenBound() {
        let items = ProjectMenu.items(
            isPinned: false, resumable: nil,
            onLaunch: { _ in }, onTogglePin: {},
            onCopySecretPath: {}
        )
        XCTAssertTrue(items.compactMap { $0?.title }.contains("复制密钥路径"))
    }

    /// 目录都没了就别提密钥了 —— 那一档只留「从列表移除」是刻意的，
    /// 每多一个可点项都是在把刚修好的静默失败又造一遍。
    func testMissingProjectStillOnlyOffersRemoval() {
        let items = ProjectMenu.items(
            isPinned: false, resumable: nil, isMissing: true,
            onLaunch: { _ in }, onTogglePin: {},
            onRemove: {}, onCopySecretPath: {}
        )
        XCTAssertFalse(items.compactMap { $0?.title }.contains("复制密钥路径"))
    }
}
