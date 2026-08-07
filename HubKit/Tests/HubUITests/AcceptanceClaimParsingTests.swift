import XCTest
@testable import HubUI

/// 解析 Claude 的逐条自查回答。
///
/// 这段解析的输入是**一段长对话末尾的自由文本**，不是干净的 API 返回。
/// 模型在这个位置加客套话、改格式、只答一半都是常态。解析失败是静默的
/// （表现为"清单一直没进展"），所以每种畸形都要单独钉住。
final class AcceptanceClaimParsingTests: XCTestCase {

    private func parse(_ text: String) -> [AcceptanceClaim]? {
        HookCoordinator.parseClaims(text)
    }

    // MARK: - 正常与包装

    func testParsesBareJSON() {
        let claims = parse(#"{"items":[{"id":"a1","done":true,"evidence":"改了 x.swift"}]}"#)

        XCTAssertEqual(claims?.count, 1)
        XCTAssertEqual(claims?.first?.id, "a1")
        XCTAssertEqual(claims?.first?.done, true)
        XCTAssertEqual(claims?.first?.evidence, "改了 x.swift")
    }

    func testStripsCodeFence() {
        let text = """
        ```json
        {"items":[{"id":"a1","done":true,"evidence":"改了 x.swift"}]}
        ```
        """
        XCTAssertEqual(parse(text)?.count, 1)
    }

    /// 模型在 JSON 前后写一段话是常态，尤其是在长对话末尾。
    func testToleratesProseAroundTheJSON() {
        let text = """
        我逐条核对了一遍：

        ```json
        {"items":[{"id":"a1","done":false,"evidence":"这条没动"}]}
        ```

        要我现在把没做的补上吗？
        """
        XCTAssertEqual(parse(text)?.first?.done, false)
    }

    // MARK: - 含糊一律按「没做」算

    /// **`done` 缺失时必须按没做算。**
    ///
    /// 方向是刻意的：把含糊不清当成"做完了"，等于给虚报开了个免检通道 ——
    /// 模型只要省略这个字段就能让一条要点被标记成已完成。
    /// 而这个功能存在的全部理由就是不给虚报留口子。
    func testMissingDoneCountsAsNotDone() {
        XCTAssertEqual(parse(#"{"items":[{"id":"a1","evidence":"呃"}]}"#)?.first?.done, false)
    }

    /// `done` 不是布尔（字符串 "true"、数字 1）同样按没做算。
    func testNonBooleanDoneCountsAsNotDone() {
        XCTAssertEqual(parse(#"{"items":[{"id":"a1","done":"true"}]}"#)?.first?.done, false)
        XCTAssertEqual(parse(#"{"items":[{"id":"a1","done":1}]}"#)?.first?.done, false)
    }

    // MARK: - 畸形输入不能崩也不能误判

    /// 没有 id 的条目对不上号，只能丢掉 —— 但不能连累同一批里正常的那些。
    func testSkipsEntriesWithoutAnID() {
        let claims = parse(#"{"items":[{"done":true},{"id":"","done":true},{"id":"ok","done":true}]}"#)

        XCTAssertEqual(claims?.map(\.id), ["ok"])
    }

    /// 完全不是 JSON —— 它多半是直接去补做遗漏项了（那其实是好事）。
    /// 返回 nil 让调用方什么都别做，退回旁路复核。
    func testProseOnlyReplyYieldsNil() {
        XCTAssertNil(parse("好的，我把漏掉的两条补上了，现在都跑通了。"))
    }

    func testMissingItemsKeyYieldsNil() {
        XCTAssertNil(parse(#"{"points":[{"id":"a1"}]}"#))
    }

    func testEmptyReplyYieldsNil() {
        XCTAssertNil(parse(""))
    }

    /// 空数组是"跑通了但一条都没答" —— 和解析失败不一样，
    /// 但调用方对两者都是什么都不做，所以这里只要求不崩。
    func testEmptyItemsArrayIsHandled() {
        XCTAssertEqual(parse(#"{"items":[]}"#)?.isEmpty, true)
    }

    func testMissingEvidenceBecomesEmptyString() {
        XCTAssertEqual(parse(#"{"items":[{"id":"a1","done":true}]}"#)?.first?.evidence, "")
    }
}
