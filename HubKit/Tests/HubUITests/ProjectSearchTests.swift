import XCTest
@testable import HubUI

/// 验收页项目选择器的模糊匹配。
///
/// 这块单独测是因为它有个容易写错的边界：子序列匹配**必须按顺序**。
/// 写成"每个字符都出现过"的话 `sod` 也能匹配到 `demo-ios`，
/// 搜索结果会变成噪音，而这种错在肉眼看列表时很难发现。
final class ProjectSearchTests: XCTestCase {

    private func matches(_ needle: String, _ haystack: String) -> Bool {
        AcceptancePane.isSubsequence(needle, of: haystack)
    }

    func testMatchesAnAbbreviation() {
        XCTAssertTrue(matches("dios", "demo-ios"))
        XCTAssertTrue(matches("dand", "demo-android"))
        XCTAssertTrue(matches("chub", "claude-hub"))
    }

    /// **顺序必须算数。** 这条是这个函数唯一真正的约束。
    func testRespectsOrder() {
        XCTAssertFalse(matches("sod", "demo-ios"), "字符齐了但顺序不对，不该匹配")
        XCTAssertFalse(matches("bahc", "claude-hub"))
    }

    func testRejectsMissingCharacters() {
        XCTAssertFalse(matches("diosx", "demo-ios"))
        XCTAssertFalse(matches("z", "claude-hub"))
    }

    func testEmptyNeedleMatchesEverything() {
        XCTAssertTrue(matches("", "claude-hub"))
    }

    /// 每个字符只能消费一次 —— 否则 `iii` 会匹配上只有一个 i 的名字。
    func testDoesNotReuseTheSameCharacter() {
        XCTAssertFalse(matches("ii", "demo-ios"))
        XCTAssertTrue(matches("oo", "demo-ios"))
    }
}
