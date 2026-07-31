import XCTest
@testable import HubUI

/// 只测 `sanitize` —— 它是回写链路里唯一的纯函数，也是最不能出错的一环。
/// 真正的发送要跑 tmux / AppleScript，那部分在实机上按靶子仓库验证。
@MainActor
final class TerminalReplyTests: XCTestCase {

    private func reject(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        switch TerminalReply.sanitize(input) {
        case .success(let value):
            XCTFail("不该通过：\(input.debugDescription) → \(value)", file: file, line: line)
        case .failure(let outcome):
            guard case .rejected = outcome else {
                return XCTFail("应该是 rejected，实际 \(outcome)", file: file, line: line)
            }
        }
    }

    private func accept(
        _ input: String, equals expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch TerminalReply.sanitize(input) {
        case .success(let value):
            XCTAssertEqual(value, expected, file: file, line: line)
        case .failure(let outcome):
            XCTFail("不该被拒：\(outcome)", file: file, line: line)
        }
    }

    func testAcceptsPlainSingleLine() {
        accept("是", equals: "是")
        accept("  继续  ", equals: "继续")
        accept("1", equals: "1")
        accept("是的，请推送到 live", equals: "是的，请推送到 live")
    }

    func testRejectsEmpty() {
        reject("")
        reject("   ")
        reject("\n\n")
    }

    /// 换行会被终端当成"再敲一次回车"，等于凭空多发一条输入 ——
    /// 用户确认的是第一行，第二行是他没看过、没同意过的。
    func testRejectsMultiline() {
        reject("是\n然后推送")
        reject("第一行\r第二行")
    }

    /// 控制字符能触发终端自己的快捷键，甚至改变终端模式。
    /// ESC 尤其危险：它是所有 ANSI 序列的开头。
    func testRejectsControlCharacters() {
        reject("是\u{1B}[A")        // ESC + 上方向键
        reject("确认\u{03}")         // Ctrl-C
        reject("\u{07}")            // BEL
        reject("a\u{00}b")          // NUL
    }

    /// 长度上限：快捷回答本来就只有几个字，长内容说明出了别的问题。
    func testRejectsOverlyLongInput() {
        reject(String(repeating: "长", count: 201))
        accept(String(repeating: "长", count: 200),
               equals: String(repeating: "长", count: 200))
    }

    /// 制表符在终端里会触发补全，夹在中间的必须拒掉。
    /// 结尾的那个会先被 trim 掉（`whitespacesAndNewlines` 含 tab），
    /// 剩下的是干净的一行，放行是对的。
    func testTabHandling() {
        reject("是\t确认")
        accept("是\t", equals: "是")
    }
}
