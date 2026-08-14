import HubCore
import HubProbe
import XCTest
@testable import HubUI

/// 「关掉终端窗口就结束会话」。
///
/// 用户选的是这一侧，但紧接着补了一句「那我也打不开了呀」—— 所以这里守的
/// 从来不只是"杀得掉"，而是**杀之前记下来了、之后接得回去**，
/// 以及**不该杀的一个都没碰**。
///
/// 会真去 kill 的那一步（`SessionReaper.kill`）没法在单测里安全执行，
/// 所以这里钉的是它前面那些判断：谁进候选、宽限期、连续确认、名册记录。
@MainActor
final class SessionReaperTests: XCTestCase {

    private func session(
        _ id: String, pid: pid_t, cwd: String = "/Users/me/code/app", startedAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            sessionId: id, pid: pid, cwd: cwd, name: "app-a1",
            status: .idle, rawStatus: "idle", kind: .interactive,
            startedAt: startedAt
        )
    }

    private func pane(_ sessionName: String, panePid: pid_t) -> TmuxPane {
        TmuxPane(
            sessionName: sessionName, windowId: "@0", windowName: "app",
            paneId: "%0", panePid: panePid, currentPath: "/Users/me/code/app",
            currentCommand: "claude"
        )
    }

    // MARK: - 宽限期

    /// **刚起来的会话不能碰。**
    ///
    /// `createSession` 是先建 detached 的 tmux 会话、再让终端去 attach 的，
    /// iTerm 冷启动那几秒客户端数就是 0。没有宽限期的话，回收器会把用户
    /// 刚点开的项目当场杀掉 —— 表现是"点了没反应"，而且查不出原因。
    func testFreshlyLaunchedSessionIsSpared() {
        let now = Date()
        let fresh = session("s1", pid: 100, startedAt: now.addingTimeInterval(-5))
        XCTAssertFalse(SessionReaper.isOldEnough(fresh, now: now, grace: 90))
    }

    func testSessionPastGraceIsEligible() {
        let now = Date()
        let old = session("s1", pid: 100, startedAt: now.addingTimeInterval(-600))
        XCTAssertTrue(SessionReaper.isOldEnough(old, now: now, grace: 90))
    }

    /// `startedAt` 缺失时**当成够久**。
    ///
    /// 缺字段的通常是早就在跑的老会话。反过来豁免的话，回收器会对最该收的
    /// 那批永远不动手 —— 一个永远不生效的开关比没有开关更糟。
    func testMissingStartTimeCountsAsOldEnough() {
        XCTAssertTrue(
            SessionReaper.isOldEnough(session("s1", pid: 100), now: Date(), grace: 90)
        )
    }

    // MARK: - 谁进候选

    /// 没客户端连着 = 用户把窗口关了 = 该收。
    func testUnattachedSessionBecomesCandidate() {
        let pairs = DetachedSessions.pairs(
            sessions: [session("s1", pid: 100)],
            panes: [pane("hub", panePid: 100)],
            attached: [],
            tree: ProcessTree(parents: [100: 1])
        )
        XCTAssertEqual(pairs.map(\.session.sessionId), ["s1"])
        XCTAssertEqual(pairs.first?.pane.paneId, "%0")
    }

    /// 终端还连着的绝不能碰。
    func testAttachedSessionIsNeverACandidate() {
        let pairs = DetachedSessions.pairs(
            sessions: [session("s1", pid: 100)],
            panes: [pane("hub", panePid: 100)],
            attached: ["hub"],
            tree: ProcessTree(parents: [100: 1])
        )
        XCTAssertTrue(pairs.isEmpty)
    }

    /// **不在 tmux 里的一个都不许碰。**
    ///
    /// VS Code 扩展、直接开的终端、bg 任务都绑不到 pane。"有没有终端连着"
    /// 这件事对它们无从判断，杀它们等于拿"不知道"当处决理由 ——
    /// 而这一档是最容易被写漏的，漏了就是批量误杀。
    func testSessionOutsideTmuxIsNeverACandidate() {
        let pairs = DetachedSessions.pairs(
            sessions: [session("s1", pid: 777)],
            panes: [pane("hub", panePid: 100)],
            attached: [],
            tree: ProcessTree(parents: [777: 1])
        )
        XCTAssertTrue(pairs.isEmpty)
    }

    /// 客户端连在别的 tmux 会话上，对这个 pane 而言等于没连。
    /// 只判断"有没有任何客户端"会漏掉这种。
    func testAttachmentIsCheckedPerTmuxSession() {
        let pairs = DetachedSessions.pairs(
            sessions: [session("s1", pid: 100)],
            panes: [pane("hub", panePid: 100)],
            attached: ["deploy"],
            tree: ProcessTree(parents: [100: 1])
        )
        XCTAssertEqual(pairs.map(\.session.sessionId), ["s1"])
    }

    // MARK: - 接得回来吗

    /// **判据是磁盘上那份 transcript，不是"有没有 sessionId"。**
    ///
    /// 实机撞到过：一个 11:35 起来、只停在提示符上、一句话都没说过的会话，
    /// `~/.claude/projects/…` 里一个字节都没有。照样记进名册的话，
    /// 项目行上会长出一个「接着上次」按钮，点下去 claude 报错退出 ——
    /// 比没有这个按钮更糟。
    func testSessionWithoutTranscriptIsNotResumable() throws {
        let root = try makeProjectsDir()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(
            SessionReaper.isResumable(
                cwd: "/Users/me/code/app",
                sessionId: "3171fac8-ed45-4437-8a83-2da2d601add9",
                reader: TranscriptReader(projectsDirectory: root)
            )
        )
    }

    func testSessionWithTranscriptIsResumable() throws {
        let root = try makeProjectsDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = "3171fac8-ed45-4437-8a83-2da2d601add9"
        let dir = root.appendingPathComponent("-Users-me-code-app", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("\(id).jsonl"))

        XCTAssertTrue(
            SessionReaper.isResumable(
                cwd: "/Users/me/code/app", sessionId: id,
                reader: TranscriptReader(projectsDirectory: root)
            )
        )
    }

    private func makeProjectsDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - 开关

    /// **默认开着** —— 用户明确选了「关窗即结束」。
    func testReapingIsOnByDefault() {
        XCTAssertTrue(SessionReaper(store: SessionStore(), closed: store(), url: nil).enabled)
    }

    func testSwitchSurvivesRestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reaper-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SessionReaper(store: SessionStore(), closed: store(), url: url)
        first.enabled = false
        XCTAssertFalse(
            SessionReaper(store: SessionStore(), closed: store(), url: url).enabled,
            "关掉的开关重启后又自己打开 = 一个会杀进程的东西不听话"
        )
    }

    private func store() -> ClosedSessionStore { ClosedSessionStore(url: nil) }
}

/// 被结束掉的会话名册。
///
/// 用户的原话：「那我也打不开了呀」。名册是「关窗即结束」能成立的**前提** ——
/// transcript 一直在磁盘上，丢的只是那个 sessionId，杀之前不记就真的没了，
/// 之后只能靠 `claude --resume` 的交互列表人肉认，而那个列表里全是
/// 一模一样的项目名。
@MainActor
final class ClosedSessionStoreTests: XCTestCase {

    private func closed(
        _ id: String, cwd: String, at: Date = Date()
    ) -> ClosedSession {
        ClosedSession(sessionId: id, name: "app-a1", cwd: cwd, endedAt: at)
    }

    func testLatestForProjectFindsTheRecord() {
        let store = ClosedSessionStore(url: nil)
        store.record(closed("s1", cwd: "/Users/me/code/app"))
        XCTAssertEqual(store.latest(forProject: "/Users/me/code/app")?.sessionId, "s1")
    }

    /// **按前缀匹配。** 会话可能开在项目的子目录或 worktree 里，
    /// 只认相等会让「接着上次」在那些会话上凭空消失。
    func testLatestMatchesSessionsInSubdirectories() {
        let store = ClosedSessionStore(url: nil)
        store.record(closed("s1", cwd: "/Users/me/code/app/packages/web"))
        XCTAssertEqual(store.latest(forProject: "/Users/me/code/app")?.sessionId, "s1")
    }

    /// 别把同前缀的**兄弟目录**认成自己人。`/code/app` 不该匹配 `/code/app-old`。
    func testSiblingDirectoryIsNotAMatch() {
        let store = ClosedSessionStore(url: nil)
        store.record(closed("s1", cwd: "/Users/me/code/app-old"))
        XCTAssertNil(store.latest(forProject: "/Users/me/code/app"))
    }

    /// 最近结束的排最前 —— 用户回头去接的几乎永远是最后那一个。
    func testMostRecentComesFirst() {
        let store = ClosedSessionStore(url: nil)
        store.record(closed("old", cwd: "/Users/me/code/app"))
        store.record(closed("new", cwd: "/Users/me/code/app"))
        XCTAssertEqual(store.latest(forProject: "/Users/me/code/app")?.sessionId, "new")
    }

    /// 同一个会话被 resume、再关、再 resume，名册里只该有一条。
    func testSameSessionIsNotDuplicated() {
        let store = ClosedSessionStore(url: nil)
        store.record(closed("s1", cwd: "/Users/me/code/app"))
        store.record(closed("s1", cwd: "/Users/me/code/app"))
        XCTAssertEqual(store.sessions.count, 1)
    }

    /// 接回来了就划掉，否则界面同时显示"在跑"和"上次结束于…"，
    /// 用户不知道该信哪个。
    func testResumingForgetsTheRecord() {
        let store = ClosedSessionStore(url: nil)
        store.record(closed("s1", cwd: "/Users/me/code/app"))
        store.forget(sessionId: "s1")
        XCTAssertNil(store.latest(forProject: "/Users/me/code/app"))
    }

    /// **必须落盘。** 只活在内存里的话，app 一重启（或者崩了）
    /// 名册就空了 —— 而"杀完就找不回来"正是这套东西要避免的唯一后果。
    func testRecordSurvivesRestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("closed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        ClosedSessionStore(url: url).record(closed("s1", cwd: "/Users/me/code/app"))
        XCTAssertEqual(
            ClosedSessionStore(url: url).latest(forProject: "/Users/me/code/app")?.sessionId,
            "s1"
        )
    }
}
