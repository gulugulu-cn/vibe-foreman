import XCTest
@testable import HubCore

/// 把一条塞了好几件事的要点拆开。
///
/// 用户的观察：Claude 的一条 todo 里常常不止一件事，整条勾掉时里面
/// 做了三件还是四件从条目本身看不出来 —— **而漏掉的往往正是最后那件**。
final class SubPointSplitTests: XCTestCase {

    private func split(_ text: String) -> [String] {
        AcceptanceItem.split(text).map(\.text)
    }

    /// 本机真实数据里的样子。
    func testSplitsARealClaudeTodo() {
        XCTAssertEqual(
            split("批次2：设备自动连接（Android 地基修复→状态机→UI→iOS）"),
            ["设备自动连接", "Android 地基修复", "状态机", "UI", "iOS"]
        )
    }

    func testSplitsOnCommonDelimiters() {
        XCTAssertEqual(split("写数据层、接 UI、补测试"), ["写数据层", "接 UI", "补测试"])
        XCTAssertEqual(split("Realtime 冒烟 + /voice/session"), ["Realtime 冒烟", "voice", "session"])
        XCTAssertEqual(split("改 A；改 B"), ["改 A", "改 B"])
    }

    /// **只有一件事就别拆。**
    ///
    /// 返回空数组表示"这条本来就是单一的"—— 不是没拆出来，是不该拆。
    /// UI 靠这个区分要不要显示「n 项」徽章。
    func testSingleThingIsNotSplit() {
        XCTAssertTrue(AcceptanceItem.split("修复登录按钮点不动").isEmpty)
        XCTAssertTrue(AcceptanceItem.split("发布新版本").isEmpty)
    }

    /// **切不出来就不切。** 「深色模式双端」其实是 iOS + Android 两件，
    /// 但没有分隔符 —— 硬猜会切错，而切错比不切更糟：
    /// 用户会对着一堆莫名其妙的碎片，然后不再相信这个标注。
    func testDoesNotGuessWithoutDelimiters() {
        XCTAssertTrue(AcceptanceItem.split("批次4：深色模式双端").isEmpty)
    }

    /// 冒号前的短前缀是标题，不算一件事。
    func testDropsShortTitlePrefix() {
        XCTAssertEqual(split("阶段一：改 A、改 B"), ["改 A", "改 B"])
    }

    /// 长前缀本身就是内容，不能当标题剥掉。
    func testKeepsLongPrefixesAsContent() {
        let parts = split("把整个权限体系重构一遍：改 A、改 B")
        XCTAssertTrue(
            parts.contains { $0.contains("权限体系") },
            "标题前缀是「批次2」那种量级；再长就是内容，剥掉就丢信息了：\(parts)"
        )
    }

    /// 切碎的噪音要滤掉。
    func testFiltersOutFragments() {
        XCTAssertFalse(split("改 A、、、改 B").contains(""))
    }

    /// 构造要点时自动拆分，不用调用方记得做。
    func testItemSplitsOnConstruction() {
        let item = AcceptanceItem(text: "写数据层、接 UI", origin: .assistantTask)

        XCTAssertEqual(item.parts.map(\.text), ["写数据层", "接 UI"])
        XCTAssertEqual(item.partsTotal, 2)
        XCTAssertEqual(item.partsDone, 0)
    }

    /// 显式传了 parts 就用传进来的（从盘上读回来的场景）。
    func testExplicitPartsWin() {
        let item = AcceptanceItem(
            text: "写数据层、接 UI", origin: .assistantTask,
            parts: [SubPoint(text: "写数据层", done: true), SubPoint(text: "接 UI")]
        )

        XCTAssertEqual(item.partsDone, 1)
    }

    /// 没有分项的要点，进度按整条算。
    func testUnsplitItemCountsAsOne() {
        var item = AcceptanceItem(text: "发布新版本", origin: .userPrompt)
        XCTAssertEqual(item.partsTotal, 1)
        XCTAssertEqual(item.partsDone, 0)

        item.status = .confirmed
        XCTAssertEqual(item.partsDone, 1)
    }
}
