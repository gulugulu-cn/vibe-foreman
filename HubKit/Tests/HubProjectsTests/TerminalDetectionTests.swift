import XCTest
@testable import HubProjects

/// 「重启后开项目弹的是系统终端，不是 iTerm2」。
///
/// 根因：`Terminal.rawValue` 是 **AppleScript 名**（`iTerm2`），不是磁盘上的
/// 包名（`iTerm.app`，只有可执行文件叫 iTerm2）。旧的 `isInstalled` 拿
/// rawValue 拼 `/Applications/iTerm2.app`，永远不存在，于是 `detectTerminal()`
/// 一路降级到 macOS 终端。
///
/// 平时看不出来是因为 hub session 通常已经存在且有客户端连着，走的是
/// `addWindow`，根本不碰终端检测；只有开机后第一次建 session 才暴露。
final class TerminalDetectionTests: XCTestCase {

    /// 路径兜底必须把 `iTerm.app` 算进去 —— 这就是 bug 本身。
    func testITermPathCandidatesIncludeTheRealBundleName() {
        let paths = TerminalDispatch.installedPathCandidates(for: .iTerm)
        XCTAssertTrue(
            paths.contains("/Applications/iTerm.app"),
            "磁盘上的包叫 iTerm.app，只找 iTerm2.app 会永远找不到：\(paths)"
        )
    }

    /// 也别把 iTerm2.app 丢了 —— 有人确实会把包改成这个名字。
    func testITermPathCandidatesKeepTheAppleScriptName() {
        XCTAssertTrue(
            TerminalDispatch.installedPathCandidates(for: .iTerm)
                .contains("/Applications/iTerm2.app")
        )
    }

    /// 用户目录下的安装也要认。
    func testITermPathCandidatesCoverUserApplications() {
        let home = NSString(string: "~").expandingTildeInPath
        XCTAssertTrue(
            TerminalDispatch.installedPathCandidates(for: .iTerm)
                .contains("\(home)/Applications/iTerm.app")
        )
    }

    /// 系统终端在 `/System/Applications/Utilities/` 下，不在 `/Applications/`。
    func testSystemTerminalCandidatesCoverUtilitiesFolder() {
        XCTAssertTrue(
            TerminalDispatch.installedPathCandidates(for: .terminal)
                .contains("/System/Applications/Utilities/Terminal.app")
        )
    }

    /// AppleScript 名不能动 —— `runInTerminal` 里的 `tell application "iTerm2"`
    /// 靠的就是它。改成 "iTerm" 会让所有派发静默失败。
    func testAppleScriptNameStaysITerm2() {
        XCTAssertEqual(TerminalDispatch.Terminal.iTerm.rawValue, "iTerm2")
    }

    /// 装了 iTerm 就必须选 iTerm。本机装了才断言，没装的机器上跳过。
    func testPrefersITermWhenInstalled() throws {
        let dispatch = TerminalDispatch()
        try XCTSkipUnless(
            dispatch.isInstalled(.iTerm), "本机没装 iTerm2，跳过"
        )
        XCTAssertEqual(dispatch.detectTerminal(), .iTerm)
    }
}
