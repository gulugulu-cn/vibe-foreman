import XCTest
@testable import HubProbe
@testable import HubProjects

/// 盯住「探测失败不许当成结论」这条线。
///
/// 这组测试对应一次真实故障：app 跑久了之后右键启动新项目「点了没反应」。
/// 根子是 fd 撞顶（GUI app 从 launchd 继承的软上限只有 256）导致
/// `Process.run()` 起不来，而各处探测把"没问出来"读成了确定的否定答案。
final class LaunchProbeTests: XCTestCase {

    // MARK: - Shell.Result 的三态

    func testSpawnFailureIsNotAnAnswer() {
        let result = Shell.Result(
            status: -1, stdout: "", stderr: "EMFILE", launched: false
        )
        XCTAssertFalse(result.answered, "进程没 fork 起来，命令没有表过态")
        XCTAssertFalse(result.succeeded)
    }

    func testTimeoutIsNotAnAnswer() {
        let result = Shell.Result(
            status: 15, stdout: "", stderr: "", launched: true, timedOut: true
        )
        XCTAssertFalse(result.answered, "是我们自己把它打死的，不算它的意见")
    }

    func testNonZeroExitIsAnAnswer() {
        let result = Shell.Result(
            status: 1, stdout: "", stderr: "can't find session: hub", launched: true
        )
        XCTAssertTrue(result.answered, "跑完了、自己返回非 0 —— 这是有效的否定答案")
        XCTAssertFalse(result.succeeded)
    }

    // MARK: - has-session 的判读

    func testProbeMapsCleanExitToExists() {
        let probe = TerminalDispatch.classify(
            Shell.Result(status: 0, stdout: "", stderr: "")
        )
        XCTAssertEqual(probe, .exists)
    }

    func testProbeMapsTmuxDenialToAbsent() {
        let probe = TerminalDispatch.classify(
            Shell.Result(status: 1, stdout: "", stderr: "can't find session: hub")
        )
        XCTAssertEqual(probe, .absent)
    }

    /// **这条是整组的核心。**
    ///
    /// 退化成 `.absent` 的后果：app 会去建一个重名 session，撞
    /// `duplicate session: hub`，而那条命令原先是 `&&` 串的，attach 直接
    /// 不执行 —— 用户拿到一行红字和一个空提示符。
    func testSpawnFailureMustNotDegradeToAbsent() {
        let probe = TerminalDispatch.classify(
            Shell.Result(status: -1, stdout: "", stderr: "EMFILE", launched: false)
        )
        XCTAssertEqual(probe, .unknown)
        XCTAssertNotEqual(probe, .absent, "没问出来 ≠ session 不存在")
    }

    func testTimeoutMustNotDegradeToAbsent() {
        let probe = TerminalDispatch.classify(
            Shell.Result(status: 15, stdout: "", stderr: "", launched: true, timedOut: true)
        )
        XCTAssertEqual(probe, .unknown)
    }

    // MARK: - 建 session 的命令必须幂等

    func testLaunchScriptFallsBackToNewWindow() {
        let script = TerminalDispatch.launchScript(
            session: "hub", name: "erp-admin", path: "/tmp/hj-admin",
            command: "claude", attach: "tmux -CC attach -t hub"
        )
        XCTAssertTrue(
            script.contains("|| tmux new-window"),
            "session 已存在时必须回落到加窗口，否则撞 duplicate session"
        )
    }

    /// attach 必须无条件执行。用 `&&` 接的话，new-session 一失败就整条断掉，
    /// 用户看得到报错但看不到项目。
    func testLaunchScriptAlwaysAttaches() {
        let script = TerminalDispatch.launchScript(
            session: "hub", name: "n", path: "/tmp", command: nil,
            attach: "tmux -CC attach -t hub"
        )
        XCTAssertTrue(script.hasSuffix("; tmux -CC attach -t hub"))
        XCTAssertFalse(
            script.contains("&& tmux -CC attach"),
            "attach 不能挂在 && 后面"
        )
    }

    func testLaunchScriptQuotesPathsWithSpaces() {
        let script = TerminalDispatch.launchScript(
            session: "hub", name: "my app", path: "/tmp/a b", command: nil, attach: "x"
        )
        XCTAssertTrue(script.contains("'my app'"))
        XCTAssertTrue(script.contains("'/tmp/a b'"))
    }

    func testLaunchScriptOmitsCommandWhenNil() {
        let script = TerminalDispatch.launchScript(
            session: "hub", name: "n", path: "/tmp", command: nil, attach: "x"
        )
        // 纯终端模式：不该往命令行上挂任何东西
        XCTAssertTrue(script.contains("-c '/tmp' ||"), "nil 命令后面应直接接 ||")
    }

    // MARK: - 新窗口的 PATH

    /// **这是本次故障的真正根因。**
    ///
    /// tmux 会把调用方客户端的 PATH 带进新 pane。Hub 是 GUI app，PATH 只有
    /// `/usr/bin:/bin:/usr/sbin:/sbin`，而 `claude` 装在 `~/.local/bin`
    /// （由 `.zshrc` 加入 PATH）。直接把 "claude …" 交给 tmux 的后果实测是：
    ///
    ///     zsh:1: command not found: claude
    ///     Pane is dead (status 127)
    ///
    /// 窗口当场消失，而 `new-window` 返回 0 —— app 以为开成功了，
    /// 用户看到的是"点了没反应"。
    ///
    /// 必须带 `-i`：实测 `zsh -c` 和 `zsh -lc` 都找不到 claude，只有 `-ic` 行。
    func testCommandRunsInInteractiveLoginShell() {
        let wrapped = loginShellCommand("claude", shell: "/bin/zsh")
        XCTAssertTrue(wrapped.hasPrefix("/bin/zsh -lic "))
    }

    func testLoginShellCommandQuotesTheWholeCommand() {
        let wrapped = loginShellCommand(
            "claude --dangerously-skip-permissions", shell: "/bin/zsh"
        )
        XCTAssertEqual(wrapped, "/bin/zsh -lic 'claude --dangerously-skip-permissions'")
    }

    /// `.resumeSession` 传下来的命令自己就带单引号，包一层不能把它拆坏。
    func testLoginShellCommandSurvivesNestedQuotes() {
        let wrapped = loginShellCommand("claude --resume 'abc-123'", shell: "/bin/zsh")
        XCTAssertEqual(wrapped, #"/bin/zsh -lic 'claude --resume '\''abc-123'\'''"#)
    }

    /// 两条启动路径必须用同一套包装，否则又会变成
    /// "第一个项目能开、第二个开不了"这种只在特定顺序下暴露的谜题。
    func testLaunchScriptAlsoUsesLoginShell() {
        let script = TerminalDispatch.launchScript(
            session: "hub", name: "n", path: "/tmp", command: "claude",
            attach: "tmux -CC attach -t hub"
        )
        XCTAssertTrue(script.contains("-lic"), "createSession 那条路也得包")
    }
}
