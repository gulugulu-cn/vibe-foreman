import XCTest
@testable import HubIPC

/// socket 层的端到端测试。这条链路是 hook 和 app 之间的唯一通道，
/// 断了就等于所有通知和审批全失效，值得真的建 socket 跑一遍。
final class SocketRoundTripTests: XCTestCase {

    private var socketPath: String!

    override func setUp() {
        super.setUp()
        // 测试用短路径：Unix socket 的 sun_path 只有 104 字节，
        // 用 NSTemporaryDirectory() 拼 UUID 很容易超。
        socketPath = "/tmp/hubtest-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        unlink(socketPath)
        super.tearDown()
    }

    private func makeEvent(kind: HookEvent.Kind, summary: String? = nil) -> HookEvent {
        HookEvent(
            kind: kind, requestId: UUID().uuidString, sessionId: "s1",
            cwd: "/tmp/proj", toolName: "Bash", toolSummary: summary
        )
    }

    /// 回归测试：超时阶梯必须严格递增。
    ///
    /// 真实事故：`ApprovalCoordinator` 和 hubctl 的读超时都设成 60 秒，两者
    /// 同时到期，hubctl 先判定"没收到应答"并放行了一条 `git push --force origin main`，
    /// 而服务端其实已经决定拒绝。超时的语义从"安全拒绝"翻转成了"静默放行"。
    func testTimeoutLadderIsStrictlyIncreasing() {
        XCTAssertLessThan(
            HookTimeouts.userDecision, HookTimeouts.serverBridge,
            "服务端要留余量把用户超时的拒绝收上来"
        )
        XCTAssertLessThan(
            HookTimeouts.serverBridge, HookTimeouts.clientRead,
            "hubctl 必须等得比服务端久，否则超时会变成放行"
        )
        XCTAssertLessThan(
            HookTimeouts.clientRead, TimeInterval(HookTimeouts.hookProcess),
            "Claude 杀 hook 的时限必须最长，否则拒绝还没输出进程就没了"
        )
    }

    /// 连上了但服务端不应答 → 必须拒绝，不能放行。
    ///
    /// 判据：服务端对非高风险操作是立即应答的。能走到"无应答"说明它认为
    /// 这次操作值得拦截，只是决策环节出了问题 —— 这种情况拒绝才是安全的。
    func testNoResponseIsDistinguishedFromUnreachable() throws {
        // 服务端收下但永不应答（模拟 UI 卡死）。
        let server = HubSocketServer(path: socketPath) { _ in
            Thread.sleep(forTimeInterval: 3)
            return nil
        }
        try server.start()
        defer { server.stop() }

        let result = HubSocketClient.send(
            makeEvent(kind: .preToolUse, summary: "rm -rf /"),
            path: socketPath, waitForDecision: true, timeout: 0.5
        )

        guard case .noResponse = result else {
            return XCTFail("连上但无应答应报 .noResponse，实际是 \(result)")
        }
    }

    func testUnreachableIsReportedDistinctly() {
        let result = HubSocketClient.send(
            makeEvent(kind: .preToolUse, summary: "rm -rf /"),
            path: "/tmp/absent-\(UUID().uuidString.prefix(6)).sock",
            waitForDecision: true, timeout: 5
        )
        guard case .unreachable = result else {
            return XCTFail("连不上应报 .unreachable，实际是 \(result)")
        }
    }

    func testFireAndForgetEventReachesServer() throws {
        let received = XCTestExpectation(description: "服务端收到事件")
        nonisolated(unsafe) var seen: HookEvent?

        let server = HubSocketServer(path: socketPath) { event in
            seen = event
            received.fulfill()
            return nil
        }
        try server.start()
        defer { server.stop() }

        let result = HubSocketClient.send(
            makeEvent(kind: .stop), path: socketPath,
            waitForDecision: false, timeout: 2
        )

        wait(for: [received], timeout: 3)
        guard case .acknowledged = result else {
            return XCTFail("非审批事件应报 .acknowledged，实际是 \(result)")
        }
        XCTAssertEqual(seen?.kind, .stop)
        XCTAssertEqual(seen?.sessionId, "s1")
    }

    func testPreToolUseReceivesDecision() throws {
        let server = HubSocketServer(path: socketPath) { _ in
            HookDecision(verdict: .deny, reason: "测试拒绝")
        }
        try server.start()
        defer { server.stop() }

        let result = HubSocketClient.send(
            makeEvent(kind: .preToolUse, summary: "rm -rf /"),
            path: socketPath, waitForDecision: true, timeout: 5
        )

        guard case .decided(let decision) = result else {
            return XCTFail("应拿到明确决策，实际是 \(result)")
        }
        XCTAssertEqual(decision.verdict, .deny)
        XCTAssertEqual(decision.reason, "测试拒绝")
    }

    /// **最重要的一条**：Hub 没跑时客户端必须立刻失败，让 hook 放行。
    /// 如果这里挂住，用户的每一次工具调用都会卡 75 秒 —— 那比漏审严重得多。
    func testClientFailsFastWhenServerAbsent() {
        let start = Date()
        let result = HubSocketClient.send(
            makeEvent(kind: .preToolUse, summary: "rm -rf /"),
            path: "/tmp/definitely-not-there-\(UUID().uuidString.prefix(6)).sock",
            waitForDecision: true, timeout: 30
        )
        guard case .unreachable = result else {
            return XCTFail("连不上应报 .unreachable，实际是 \(result)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 1.0,
            "连不上时必须立刻失败，不能等到超时"
        )
    }

    func testIsHubRunningReflectsServerState() throws {
        XCTAssertFalse(HubSocketClient.isHubRunning(path: socketPath))

        let server = HubSocketServer(path: socketPath) { _ in nil }
        try server.start()
        XCTAssertTrue(HubSocketClient.isHubRunning(path: socketPath))

        server.stop()
        XCTAssertFalse(HubSocketClient.isHubRunning(path: socketPath))
    }

    /// 服务端处理器返回 nil 时，协议层会回一条明确的 allow，而不是让客户端挂住。
    func testNilHandlerResultBecomesExplicitAllow() throws {
        let server = HubSocketServer(path: socketPath) { _ in nil }
        try server.start()
        defer { server.stop() }

        let result = HubSocketClient.send(
            makeEvent(kind: .preToolUse, summary: "rm -rf /"),
            path: socketPath, waitForDecision: true, timeout: 5
        )
        guard case .decided(let decision) = result else {
            return XCTFail("应拿到明确决策，实际是 \(result)")
        }
        XCTAssertEqual(decision.verdict, .allow)
    }

    /// 上次进程被 kill -9 会留下 socket 文件，不删的话 bind 报 EADDRINUSE。
    func testStaleSocketFileIsReplaced() throws {
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let server = HubSocketServer(path: socketPath) { _ in nil }
        XCTAssertNoThrow(try server.start())
        server.stop()
    }

    func testMultipleConcurrentClients() throws {
        let count = 8
        let received = XCTestExpectation(description: "全部事件送达")
        received.expectedFulfillmentCount = count

        let server = HubSocketServer(path: socketPath) { _ in
            received.fulfill()
            return nil
        }
        try server.start()
        defer { server.stop() }

        let path = socketPath!
        DispatchQueue.concurrentPerform(iterations: count) { index in
            _ = HubSocketClient.send(
                HookEvent(
                    kind: .stop, requestId: "r\(index)", sessionId: "s\(index)", cwd: "/tmp"
                ),
                path: path, waitForDecision: false, timeout: 2
            )
        }
        wait(for: [received], timeout: 5)
    }
}
