import XCTest
@testable import HubCore
@testable import HubJump
@testable import HubProbe

/// `kind: bg` 会话的绑定。
///
/// 实测背景：bg 会话跑在 `claude bg-pty-host` daemon 下，祖先链是
/// `23402 (claude bg-spare) → 23371 (claude bg-pty-host) → 70305 (claude daemon) → 1`，
/// **完全不经过任何终端**。用户看它的地方是某个跑 `claude agents` 的 tab，
/// 那个 tab 的 jobPid 指向查看器进程（如 23360），与 23402 毫无亲缘关系。
final class BackgroundSessionBindingTests: XCTestCase {

    private func bgSession(_ pid: pid_t, id: String, name: String) -> AgentSession {
        AgentSession(
            sessionId: id, pid: pid, cwd: "/tmp", name: name,
            status: .idle, rawStatus: "idle", kind: .bg, jobId: id
        )
    }

    private func interactiveSession(_ pid: pid_t, id: String, name: String) -> AgentSession {
        AgentSession(
            sessionId: id, pid: pid, cwd: "/tmp", name: name,
            status: .busy, rawStatus: "busy", kind: .interactive
        )
    }

    private func term(_ jobPid: pid_t, _ uuid: String, name: String) -> ITermSession {
        ITermSession(sessionUUID: uuid, windowId: "3812", jobPid: jobPid, name: name)
    }

    /// 实测场景，PID 和标题都抄自本机。
    func testBgSessionBindsToViewerTabByJobName() {
        let tree = ProcessTree(parents: [
            23402: 23371, 23371: 70305, 70305: 1,     // bg 会话，挂在 daemon 下
            23360: 61126, 61126: 61125, 61125: 1,     // 查看器 tab，与上面无亲缘
        ])
        let mapping = JumpEngine.bind(
            itermSessions: [
                term(23360, "VIEWER", name: "⠐ o3-ui-memory-idempotent-fixes (Claude)"),
            ],
            claudeSessions: [
                bgSession(23402, id: "bg-1", name: "o3-ui-memory-idempotent-fixes"),
            ],
            tree: tree
        )
        XCTAssertEqual(mapping["bg-1"], "VIEWER")
    }

    /// 祖先链先跑，名字匹配只兜底。已经被祖先链认领的 tab 不能被名字匹配抢走 ——
    /// 否则一个 interactive 会话的 ai-title 里偶然含有某个 job 名就会把 tab 抢过去。
    func testAncestryBindingWinsOverNameMatching() {
        let tree = ProcessTree(parents: [
            30024: 29976, 29976: 1,
            23402: 23371, 23371: 70305, 70305: 1,
        ])
        // 这个 tab 既能被祖先链绑到 interactive 会话，标题里又恰好含 bg 会话的名字。
        let ambiguous = term(
            30024, "SHARED",
            name: "正在处理 o3-ui-memory-idempotent-fixes 相关问题"
        )
        let mapping = JumpEngine.bind(
            itermSessions: [ambiguous],
            claudeSessions: [
                interactiveSession(29976, id: "inter", name: "hub"),
                bgSession(23402, id: "bg-1", name: "o3-ui-memory-idempotent-fixes"),
            ],
            tree: tree
        )
        XCTAssertEqual(mapping["inter"], "SHARED")
        XCTAssertNil(mapping["bg-1"], "已被祖先链认领的 tab 不该再被名字匹配抢走")
    }

    /// interactive 会话**不**参与名字匹配。它的祖先链一定连得上；
    /// 连不上说明它压根不在 iTerm 里，此时按标题猜只会猜错。
    func testInteractiveSessionsDoNotFallBackToNameMatching() {
        let tree = ProcessTree(parents: [99999: 1, 30024: 1])
        let mapping = JumpEngine.bind(
            itermSessions: [term(30024, "T", name: "some-unique-session-name")],
            claudeSessions: [
                interactiveSession(99999, id: "i", name: "some-unique-session-name"),
            ],
            tree: tree
        )
        XCTAssertTrue(mapping.isEmpty)
    }

    /// 太短的名字不参与匹配，避免 `api` 这类词在别的标题里偶然命中。
    func testShortJobNamesAreNotMatchedByTitle() {
        let tree = ProcessTree(parents: [500: 1, 600: 1])
        let mapping = JumpEngine.bind(
            itermSessions: [term(600, "T", name: "deploying api to prod")],
            claudeSessions: [bgSession(500, id: "bg", name: "api")],
            tree: tree
        )
        XCTAssertTrue(mapping.isEmpty)
    }

    func testBgSessionWithoutNameIsSkipped() {
        let tree = ProcessTree(parents: [500: 1, 600: 1])
        let mapping = JumpEngine.bind(
            itermSessions: [term(600, "T", name: "anything")],
            claudeSessions: [
                AgentSession(
                    sessionId: "bg", pid: 500, cwd: "/tmp", name: nil,
                    status: .idle, rawStatus: "idle", kind: .bg
                ),
            ],
            tree: tree
        )
        XCTAssertTrue(mapping.isEmpty)
    }

    /// 两个 bg 会话不能抢同一个 tab。
    func testTwoBackgroundSessionsDoNotShareOneTab() {
        let tree = ProcessTree(parents: [500: 70305, 501: 70305, 70305: 1, 600: 1])
        let mapping = JumpEngine.bind(
            itermSessions: [term(600, "ONLY", name: "shared-prefix-alpha")],
            claudeSessions: [
                bgSession(500, id: "bg-a", name: "shared-prefix-alpha"),
                bgSession(501, id: "bg-b", name: "shared-prefix-alpha"),
            ],
            tree: tree
        )
        XCTAssertEqual(mapping.count, 1)
        XCTAssertEqual(mapping.values.first, "ONLY")
    }

    /// 没有查看器 tab 开着时，bg 会话就是绑不上 —— 这是正确行为，
    /// 跳转会降级为「只前置终端」，而不是跳到一个错误的 tab。
    func testBgSessionWithNoViewerTabRemainsUnbound() {
        let tree = ProcessTree(parents: [500: 70305, 70305: 1, 600: 1])
        let mapping = JumpEngine.bind(
            itermSessions: [term(600, "OTHER", name: "完全无关的标题")],
            claudeSessions: [bgSession(500, id: "bg", name: "some-long-job-name")],
            tree: tree
        )
        XCTAssertTrue(mapping.isEmpty)
    }
}
