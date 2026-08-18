import XCTest
@testable import HubIPC

/// 读密钥文件要被拦一下。
///
/// 这道闸只挡**诚实 agent 的手滑**：约定的用法是
/// `set -a; source '<路径>'; set +a`，而一旦改用 `Read`，
/// 文件内容就进了 transcript（0644、永久、每轮重发给 API）。
final class SensitivePathsTests: XCTestCase {

    private let classifier = RiskClassifier()

    private func envPath(_ name: String = "hj-admin-9f3a1c8d.env") -> String {
        "/Users/lizi/.vibe-foreman/env/by-project/\(name)"
    }

    /// `Read` 平时是无条件放行的（`readOnlyTools` 早退）。密钥文件是唯一的例外。
    func testReadingAVaultFileIsIntercepted() {
        XCTAssertEqual(classifier.classify(toolName: "Read", summary: envPath()), .irreversible)
        XCTAssertEqual(
            classifier.classify(
                toolName: "Read",
                summary: "/Users/lizi/Library/Application Support/claude-hub/credentials.dat"
            ),
            .irreversible
        )
        XCTAssertEqual(
            classifier.classify(
                toolName: "Read",
                summary: "/Users/lizi/Library/Application Support/claude-hub/shared-secrets.dat"
            ),
            .irreversible
        )
    }

    /// Grep / Glob 走的是同一个分支，一样要挡 —— 不然
    /// `grep -r SECRET ~/.vibe-foreman` 就绕过去了。
    func testGrepAndGlobAreAlsoIntercepted() {
        XCTAssertEqual(classifier.classify(toolName: "Grep", summary: envPath()), .irreversible)
        XCTAssertEqual(
            classifier.classify(toolName: "Glob", summary: "/Users/lizi/.vibe-foreman/env/**"),
            .irreversible
        )
    }

    /// **普通文件的 Read 必须照旧放行。**
    ///
    /// 这条守的是 `readOnlyTools` 早退那段注释里记的事：
    /// Read 一个讲 `rm -rf` 的 README 不该触发审批。新加的判断要是判宽了，
    /// 用户会开始为读文件点审批，然后把整个功能关掉。
    func testOrdinaryReadsStayNormal() {
        for path in [
            "/Users/lizi/Documents/code/hj-admin/README.md",
            "/Users/lizi/Documents/code/x/.env",
            "/Users/lizi/Library/Application Support/claude-hub/acceptance/x.json",
            "/Users/lizi/.vibe-foreman-notes.txt",
        ] {
            XCTAssertEqual(classifier.classify(toolName: "Read", summary: path), .normal, path)
        }
    }

    /// **约定的用法不能被自己拦下来。**
    ///
    /// 交给 AI 的那段话让它 `set -a; source '<路径>'; set +a`。
    /// 这个判断要是提到 `classify` 的开头（对所有工具生效），
    /// 那条命令每次都会弹审批 —— 正常流程当场被堵死。
    /// Bash 走下面的模式匹配，`\.env\b` 已经把它定成 dangerous（只记录不拦截）。
    func testTheDocumentedSourceCommandIsNotIntercepted() {
        let command = "set -a; source '\(envPath())'; set +a; go test ./..."
        let level = classifier.classify(toolName: "Bash", summary: command)
        XCTAssertLessThan(level, .irreversible, "约定的 source 用法被自己拦下来了")
        XCTAssertFalse(RiskClassifier().shouldIntercept(level))
    }

    func testEmptySummaryIsNormal() {
        XCTAssertEqual(classifier.classify(toolName: "Read", summary: nil), .normal)
        XCTAssertEqual(classifier.classify(toolName: "Read", summary: ""), .normal)
    }
}
