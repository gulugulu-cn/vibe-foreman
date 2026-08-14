import HubCore
import HubProbe
import XCTest
@testable import HubUI

/// 「终端关了，会话还显示在线」。
///
/// 实机现象：用户把 acme-erp 的终端窗口关掉，主窗口的项目行照旧亮着蓝点、
/// 写着「1 个会话」。他截图标注「实际已退出」——界面在他眼里是坏的。
///
/// 界面没坏，它只是把「进程活着」当成了「会话在线」。关掉终端只是 detach：
/// claude 的父进程是 tmux server，窗口没了进程照跑，`kill(pid, 0)` 依然为真。
///
/// 所以这里要钉住的是**区分**：在 tmux 里且没客户端连着 = detached；
/// 有客户端 = 正常；根本不在 tmux 里 = 不知道，不许报 detached。
final class DetachedSessionTests: XCTestCase {

    private func session(_ id: String, pid: pid_t, cwd: String = "/tmp/x") -> AgentSession {
        AgentSession(
            sessionId: id, pid: pid, cwd: cwd,
            status: .idle, rawStatus: "idle", kind: .interactive
        )
    }

    private func pane(_ sessionName: String, panePid: pid_t) -> TmuxPane {
        TmuxPane(
            sessionName: sessionName, windowId: "@0", windowName: "acme-erp",
            paneId: "%0", panePid: panePid, currentPath: "/tmp/x", currentCommand: "claude"
        )
    }

    /// 用户关掉窗口后的实机拓扑：hub 这个 tmux 会话一个客户端都没有。
    func testSessionInUnattachedTmuxIsDetached() {
        let tree = ProcessTree(parents: [6450: 6449, 6449: 1])
        let ids = SessionStore.detachedIds(
            sessions: [session("s1", pid: 6450)],
            panes: [pane("hub", panePid: 6449)],
            attached: [],
            tree: tree
        )
        XCTAssertEqual(ids, ["s1"])
    }

    /// 有客户端连着就是正常在线，别误报。
    func testAttachedSessionIsNotDetached() {
        let tree = ProcessTree(parents: [6450: 6449, 6449: 1])
        let ids = SessionStore.detachedIds(
            sessions: [session("s1", pid: 6450)],
            panes: [pane("hub", panePid: 6449)],
            attached: ["hub"],
            tree: tree
        )
        XCTAssertTrue(ids.isEmpty)
    }

    /// 客户端连的是**别的** tmux 会话 —— 对 hub 来说等于没连。
    /// 只判断"有没有任何客户端"会漏掉这种。
    func testAttachmentIsPerTmuxSession() {
        let tree = ProcessTree(parents: [6450: 6449, 6449: 1])
        let ids = SessionStore.detachedIds(
            sessions: [session("s1", pid: 6450)],
            panes: [pane("hub", panePid: 6449)],
            attached: ["other"],
            tree: tree
        )
        XCTAssertEqual(ids, ["s1"])
    }

    /// **绑不到 pane 的不算 detached。**
    ///
    /// 那是「根本不在 tmux 里」——VS Code 扩展、直接开的终端、后台任务。
    /// 它们有没有终端连着这里判断不了，报成 detached 就是拿"不知道"当结论，
    /// 会让一堆正常会话集体显示成"终端已关"。
    func testSessionOutsideTmuxIsNotReportedDetached() {
        let ids = SessionStore.detachedIds(
            sessions: [session("s1", pid: 999)],
            panes: [pane("hub", panePid: 6449)],
            attached: [],
            tree: ProcessTree(parents: [999: 1])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    /// tmux 压根没跑（listPanes 空）时不该有任何判断。
    func testNoPanesMeansNoVerdict() {
        let ids = SessionStore.detachedIds(
            sessions: [session("s1", pid: 6450)],
            panes: [],
            attached: [],
            tree: ProcessTree(parents: [6450: 6449, 6449: 1])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - 文案

    /// 全断开时必须说出来，不能只写「1 个会话」——那正是用户认定界面在撒谎的那句。
    func testSummarySaysTerminalClosedWhenAllDetached() {
        XCTAssertEqual(
            ProjectsPane.sessionSummary(running: 1, detached: 1), "1 个会话 · 终端已关"
        )
        XCTAssertEqual(
            ProjectsPane.sessionSummary(running: 3, detached: 3), "3 个会话 · 终端都已关"
        )
    }

    /// 部分断开要报出几个，否则用户不知道该去开哪个。
    func testSummaryCountsPartialDetachment() {
        XCTAssertEqual(
            ProjectsPane.sessionSummary(running: 3, detached: 1), "3 个会话 · 1 个终端已关"
        )
    }

    /// 全连着时保持原样，别给正常情况加噪音。
    func testSummaryStaysQuietWhenAllAttached() {
        XCTAssertEqual(ProjectsPane.sessionSummary(running: 2, detached: 0), "2 个会话")
        XCTAssertNil(ProjectsPane.sessionSummary(running: 0, detached: 0))
    }
}
