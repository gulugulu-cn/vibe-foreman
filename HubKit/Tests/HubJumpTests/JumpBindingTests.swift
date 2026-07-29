import XCTest
@testable import HubCore
@testable import HubJump
@testable import HubProbe

/// 绑定逻辑是整个跳转方案的核心，也是最容易出错的地方。
/// AppleScript 和 sysctl 没法在测试里跑，所以把纯逻辑抽了出来单独测。
///
/// 下面的进程树全部抄自本机实测（见方案文档 §1.2），不是编造的场景。
final class JumpBindingTests: XCTestCase {

    private func session(_ pid: pid_t, _ id: String, cwd: String = "/tmp") -> AgentSession {
        AgentSession(
            sessionId: id, pid: pid, cwd: cwd,
            status: .busy, rawStatus: "busy", kind: .interactive
        )
    }

    private func term(_ jobPid: pid_t, _ uuid: String) -> ITermSession {
        ITermSession(sessionUUID: uuid, windowId: "3812", jobPid: jobPid, name: "irrelevant")
    }

    /// 实测链路一：tmux -CC 会话，claude 是 pane 根进程，node 是它的子进程。
    ///   30024(node) → 29976(claude ✓) → 25111(tmux)
    func testBindsThroughNodeChildInTmuxSession() {
        let tree = ProcessTree(parents: [30024: 29976, 29976: 25111, 25111: 1])
        let mapping = JumpEngine.bind(
            itermSessions: [term(30024, "UUID-A")],
            claudeSessions: [session(29976, "claude-hub-session")],
            tree: tree
        )
        XCTAssertEqual(mapping["claude-hub-session"], "UUID-A")
    }

    /// 实测链路二：中间隔着 npm exec 的 MCP 服务进程，祖先链更深。
    ///   91852(node) → 91758(npm exec) → 90252(claude ✓) → 25111(tmux)
    func testBindsThroughDeeperChainViaNpmExec() {
        let tree = ProcessTree(parents: [
            91852: 91758, 91758: 90252, 90252: 25111, 25111: 1,
        ])
        let mapping = JumpEngine.bind(
            itermSessions: [term(91852, "UUID-B")],
            claudeSessions: [session(90252, "acme-admin-session")],
            tree: tree
        )
        XCTAssertEqual(mapping["acme-admin-session"], "UUID-B")
    }

    /// 实测链路三：**非 tmux** 的 iTerm 原生会话，祖先链通到 iTermServer。
    /// 同一套算法必须覆盖这种情况 —— 这正是"任意终端，非 tmux"需求的实现依据。
    func testBindsNonTmuxNativeItermSession() {
        let tree = ProcessTree(parents: [
            23360: 61126, 61126: 61125, 61125: 21560, 21560: 21558, 21558: 1,
        ])
        let mapping = JumpEngine.bind(
            itermSessions: [term(23360, "UUID-C")],
            claudeSessions: [session(61126, "bg-session")],
            tree: tree
        )
        XCTAssertEqual(mapping["bg-session"], "UUID-C")
    }

    /// jobPid 恰好就是 claude 进程本身（pane 里没有前台子进程时）。
    func testBindsWhenJobPidIsTheClaudeProcessItself() {
        let tree = ProcessTree(parents: [29976: 25111, 25111: 1])
        let mapping = JumpEngine.bind(
            itermSessions: [term(29976, "UUID-D")],
            claudeSessions: [session(29976, "direct")],
            tree: tree
        )
        XCTAssertEqual(mapping["direct"], "UUID-D")
    }

    /// 多个会话同时存在时不能串味 —— 这是旧实现按标题子串匹配最容易犯的错
    /// （多个 tab 标题都叫 "Claude Code" 就会跳错）。
    func testMultipleSessionsDoNotCrossBind() {
        let tree = ProcessTree(parents: [
            30024: 29976, 29976: 25111,
            91852: 91758, 91758: 90252, 90252: 25111,
            97188: 97138, 97138: 25111,
            25111: 1,
        ])
        let mapping = JumpEngine.bind(
            itermSessions: [term(30024, "A"), term(91852, "B"), term(97188, "C")],
            claudeSessions: [
                session(29976, "hub"), session(90252, "admin"), session(97138, "image"),
            ],
            tree: tree
        )
        XCTAssertEqual(mapping, ["hub": "A", "admin": "B", "image": "C"])
    }

    /// 非 Claude 的 tab（比如一个普通 zsh）不该被绑到任何会话上。
    func testPlainShellTabBindsToNothing() {
        let tree = ProcessTree(parents: [5608: 25111, 25111: 1])
        let mapping = JumpEngine.bind(
            itermSessions: [term(5608, "UUID-ZSH")],
            claudeSessions: [session(29976, "elsewhere")],
            tree: tree
        )
        XCTAssertTrue(mapping.isEmpty)
    }

    /// 进程树里查不到 jobPid（进程刚退出，快照有撕裂）时不能崩，静默跳过即可。
    func testUnknownJobPidIsSkipped() {
        let tree = ProcessTree(parents: [29976: 25111])
        let mapping = JumpEngine.bind(
            itermSessions: [term(999_999, "GHOST"), term(29976, "REAL")],
            claudeSessions: [session(29976, "s")],
            tree: tree
        )
        XCTAssertEqual(mapping, ["s": "REAL"])
    }

    func testNoClaudeSessionsYieldsEmptyMapping() {
        let tree = ProcessTree(parents: [30024: 29976, 29976: 1])
        XCTAssertTrue(JumpEngine.bind(
            itermSessions: [term(30024, "A")], claudeSessions: [], tree: tree
        ).isEmpty)
    }

    /// 最近的祖先优先：嵌套 claude（claude 内又起了一个 claude）时
    /// 应该绑到里层那个，因为那才是这个 tab 前台真正在跑的会话。
    func testNearestAncestorWins() {
        let tree = ProcessTree(parents: [500: 400, 400: 300, 300: 1])
        let mapping = JumpEngine.bind(
            itermSessions: [term(500, "T")],
            claudeSessions: [session(400, "inner"), session(300, "outer")],
            tree: tree
        )
        XCTAssertEqual(mapping["inner"], "T")
        XCTAssertNil(mapping["outer"])
    }
}

/// 进程树遍历本身的边界情况。
final class ProcessTreeTests: XCTestCase {

    func testAncestryIncludesSelfAndStopsAtRoot() {
        let tree = ProcessTree(parents: [30024: 29976, 29976: 25111, 25111: 1, 1: 0])
        XCTAssertEqual(tree.ancestry(of: 30024), [30024, 29976, 25111, 1])
    }

    /// 快照撕裂可能造出环。必须截断而不是死循环 —— 这会挂死整个跳转。
    func testCyclicParentChainTerminates() {
        let tree = ProcessTree(parents: [10: 20, 20: 30, 30: 10])
        let chain = tree.ancestry(of: 10)
        XCTAssertEqual(chain, [10, 20, 30])
    }

    func testSelfParentTerminates() {
        let tree = ProcessTree(parents: [10: 10])
        XCTAssertEqual(tree.ancestry(of: 10), [10])
    }

    func testDepthLimitIsRespected() {
        var parents: [pid_t: pid_t] = [:]
        for i in 1..<200 { parents[pid_t(i)] = pid_t(i + 1) }
        XCTAssertEqual(tree(parents).ancestry(of: 1, limit: 5).count, 5)
    }

    func testMissingPidYieldsItselfOnly() {
        XCTAssertEqual(ProcessTree(parents: [:]).ancestry(of: 42), [42])
    }

    private func tree(_ parents: [pid_t: pid_t]) -> ProcessTree {
        ProcessTree(parents: parents)
    }
}
