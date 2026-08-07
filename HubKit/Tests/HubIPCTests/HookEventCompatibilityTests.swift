import XCTest
@testable import HubIPC

/// 新旧 hubctl / Hub 混用时的兼容性。
///
/// 这不是理论问题：`hubctl` 装在 `~/.local/bin/`，而 Hub 在 `/Applications`。
/// 用户升级了 app 却没重跑 `setup-swift-hooks.sh`（或者反过来）是常态，
/// 两边版本对不上必须**退化**而不是**崩掉**。
final class HookEventCompatibilityTests: XCTestCase {

    /// 旧 hubctl 发来的 JSON 没有新增字段 —— 必须能解出来。
    ///
    /// 解不出来的后果不是"少个字段"，是这条事件整个被丢掉：
    /// 通知不弹、审批不拦。所以新增字段一律可选。
    func testDecodesPayloadWithoutTheNewFields() throws {
        let legacy = """
        {"kind":"stop","requestId":"r1","sessionId":"s1","cwd":"/tmp"}
        """

        let event = try JSONDecoder().decode(HookEvent.self, from: Data(legacy.utf8))

        XCTAssertEqual(event.kind, .stop)
        XCTAssertNil(event.promptText)
        XCTAssertNil(event.stopHookActive)
    }

    func testRoundTripsTheNewFields() throws {
        let original = HookEvent(
            kind: .userPromptSubmit,
            requestId: "r1",
            sessionId: "s1",
            cwd: "/tmp",
            stopHookActive: true,
            promptText: "做一个观察者"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HookEvent.self, from: data)

        XCTAssertEqual(decoded.kind, .userPromptSubmit)
        XCTAssertEqual(decoded.promptText, "做一个观察者")
        XCTAssertEqual(decoded.stopHookActive, true)
    }

    /// 旧版 Hub 收到新 hubctl 发来的 `userPromptSubmit` 会解不出 kind。
    ///
    /// 这条**不是**在断言它能解出来（它解不出来，那是对的），而是固化
    /// "新增 kind 会让旧 Hub 整条事件解码失败"这个事实：所以发布时
    /// app 和 hubctl 必须一起更新，`build-swift-app.sh` 两个都编不是可选项。
    func testUnknownKindFailsDecodingLoudly() {
        let future = """
        {"kind":"somethingNew","requestId":"r","sessionId":"s","cwd":"/tmp"}
        """

        XCTAssertThrowsError(
            try JSONDecoder().decode(HookEvent.self, from: Data(future.utf8))
        )
    }
}
