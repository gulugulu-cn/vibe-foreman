import XCTest
@testable import HubCore

final class AgentSessionTests: XCTestCase {

    /// 真实样本，逐字段抄自本机 ~/.claude/sessions/34624.json。
    private let realBusySample = """
    {"pid":34624,"sessionId":"8ba8f1c1-0039-4295-8193-78fa6056578f",\
    "cwd":"/Users/dev/Documents/code/shopify/storefront-a","startedAt":1785140285143,\
    "procStart":"Mon Jul 27 08:18:03 2026","version":"2.1.220","peerProtocol":1,\
    "kind":"interactive","entrypoint":"cli","name":"storefront-a-c3","nameSource":"derived",\
    "status":"busy","updatedAt":1785225171453,"statusUpdatedAt":1785225171453}
    """

    func testDecodesRealBusySample() throws {
        let session = try XCTUnwrap(AgentSession.decode(from: Data(realBusySample.utf8)))

        XCTAssertEqual(session.sessionId, "8ba8f1c1-0039-4295-8193-78fa6056578f")
        XCTAssertEqual(session.pid, 34624)
        XCTAssertEqual(session.cwd, "/Users/dev/Documents/code/shopify/storefront-a")
        XCTAssertEqual(session.name, "storefront-a-c3")
        XCTAssertEqual(session.status, .busy)
        XCTAssertEqual(session.kind, .interactive)
        XCTAssertEqual(session.version, "2.1.220")
        XCTAssertNil(session.waitingFor)
        XCTAssertEqual(session.fallbackProjectName, "storefront-a")
    }

    func testDecodesWaitingWithReason() throws {
        let json = """
        {"pid":34624,"sessionId":"abc","cwd":"/tmp/x","status":"waiting",\
        "kind":"interactive","waitingFor":"input needed"}
        """
        let session = try XCTUnwrap(AgentSession.decode(from: Data(json.utf8)))
        XCTAssertEqual(session.status, .waiting)
        XCTAssertEqual(session.waitingFor, "input needed")
    }

    func testDecodesBackgroundSessionWithJobId() throws {
        let json = """
        {"pid":23402,"sessionId":"171d69d9","cwd":"/tmp/x","kind":"bg",\
        "status":"shell","jobId":"171d69d9"}
        """
        let session = try XCTUnwrap(AgentSession.decode(from: Data(json.utf8)))
        XCTAssertEqual(session.kind, .bg)
        XCTAssertEqual(session.jobId, "171d69d9")
        XCTAssertEqual(session.status, .shell)
    }

    /// Claude Code 将来可能加新的 status 取值。不能因此丢掉整个会话，
    /// 也不能把未知状态误判成 idle（那会让它在 UI 上装作没事）。
    func testUnknownStatusIsPreservedNotDropped() throws {
        let json = #"{"pid":1,"sessionId":"x","cwd":"/tmp","status":"compacting"}"#
        let session = try XCTUnwrap(AgentSession.decode(from: Data(json.utf8)))
        XCTAssertEqual(session.status, .unknown)
        XCTAssertEqual(session.rawStatus, "compacting")
    }

    /// schema 变动导致缺字段时，只有三个硬要求缺失才该整条丢弃。
    func testRejectsRecordsMissingIdentityFields() {
        XCTAssertNil(AgentSession.decode(from: Data(#"{"sessionId":"x","cwd":"/tmp"}"#.utf8)))
        XCTAssertNil(AgentSession.decode(from: Data(#"{"pid":1,"cwd":"/tmp"}"#.utf8)))
        XCTAssertNil(AgentSession.decode(from: Data(#"{"pid":1,"sessionId":"x"}"#.utf8)))
        XCTAssertNil(AgentSession.decode(from: Data(#"{"pid":1,"sessionId":"","cwd":"/tmp"}"#.utf8)))
        XCTAssertNil(AgentSession.decode(from: Data("not json".utf8)))
    }

    func testMissingOptionalFieldsStillDecodes() throws {
        let json = #"{"pid":1,"sessionId":"x","cwd":"/tmp/proj"}"#
        let session = try XCTUnwrap(AgentSession.decode(from: Data(json.utf8)))
        XCTAssertEqual(session.status, .unknown)
        XCTAssertEqual(session.kind, .unknown)
        XCTAssertNil(session.name)
        XCTAssertNil(session.startedAt)
    }

    /// 排序即 UI 优先级。waiting 必须永远第一，unknown 必须永远最后 ——
    /// 后者保证 Claude 新增状态取值时不会意外抢占最显眼的位置。
    func testStatusOrderingPutsWaitingFirstAndUnknownLast() {
        let shuffled: [SessionStatus] = [.idle, .unknown, .busy, .waiting, .shell]
        XCTAssertEqual(shuffled.sorted(), [.waiting, .busy, .shell, .idle, .unknown])
    }

    func testIsActiveExcludesIdleAndUnknown() {
        XCTAssertTrue(SessionStatus.busy.isActive)
        XCTAssertTrue(SessionStatus.waiting.isActive)
        XCTAssertTrue(SessionStatus.shell.isActive)
        XCTAssertFalse(SessionStatus.idle.isActive)
        XCTAssertFalse(SessionStatus.unknown.isActive)
    }

    func testMillisecondTimestampsConvertToDates() throws {
        let session = try XCTUnwrap(AgentSession.decode(from: Data(realBusySample.utf8)))
        let started = try XCTUnwrap(session.startedAt)
        XCTAssertEqual(started.timeIntervalSince1970, 1_785_140_285.143, accuracy: 0.001)
    }
}
