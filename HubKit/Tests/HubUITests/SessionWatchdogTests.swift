import HubCore
import HubProjects
import XCTest
@testable import HubUI

/// 会话观察者的状态与配置。
///
/// 真正容易出错的判断（在不在干活、有没有草稿）在 `PaneActivity` 里，
/// 是纯函数、单独测。这里测的是配置、轮换和持久化。
@MainActor
final class SessionWatchdogTests: XCTestCase {

    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func make(url: URL?) -> SessionWatchdog {
        SessionWatchdog(
            store: SessionStore(),
            projects: ProjectStore(yamlURL: nil, pinURL: nil),
            acceptance: AcceptanceStore(directory: nil),
            url: url
        )
    }

    /// **默认必须是关的。**
    ///
    /// 它会往用户的终端里敲字。装上 Hub 的人不该在不知情时被自动插话。
    func testNothingIsWatchedByDefault() {
        XCTAssertTrue(make(url: nil).watching.isEmpty)
    }

    func testWatchingSurvivesRestart() {
        let first = make(url: tempURL)
        first.setWatching(true, "/tmp/proj")

        XCTAssertTrue(make(url: tempURL).isWatching("/tmp/proj"))
    }

    func testCanStopWatching() {
        let watchdog = make(url: tempURL)
        watchdog.setWatching(true, "/tmp/proj")
        watchdog.setWatching(false, "/tmp/proj")

        XCTAssertFalse(make(url: tempURL).isWatching("/tmp/proj"))
    }

    func testNilURLDoesNotTouchTheDisk() throws {
        let watchdog = make(url: nil)
        watchdog.setWatching(true, "/tmp/proj")

        XCTAssertTrue(watchdog.isWatching("/tmp/proj"), "内存里要生效")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    // MARK: - 追问清单

    /// 没配过就用默认那份 —— 不能是空的。
    ///
    /// 空清单的盯梢会「在盯着」但永远不说话，用户从开关上看不出区别。
    func testFallsBackToDefaultProbes() {
        let watchdog = make(url: nil)

        XCTAssertFalse(watchdog.probeList(for: "/tmp/proj").isEmpty)
        XCTAssertEqual(watchdog.probeList(for: "/tmp/proj"), SessionWatchdog.defaultProbes)
    }

    func testCustomProbesWin() {
        let watchdog = make(url: nil)
        watchdog.setProbes(["问题一", "问题二"], for: "/tmp/proj")

        XCTAssertEqual(watchdog.probeList(for: "/tmp/proj"), ["问题一", "问题二"])
    }

    /// 空行要滤掉 —— 界面上是个多行文本框，用户敲回车很自然。
    /// 不滤的话会往终端发一条空消息。
    func testBlankLinesAreDropped() {
        let watchdog = make(url: nil)
        watchdog.setProbes(["问题一", "", "   ", "问题二"], for: "/tmp/proj")

        XCTAssertEqual(watchdog.probeList(for: "/tmp/proj"), ["问题一", "问题二"])
    }

    /// 全删光时退回默认，而不是变成"永不说话"。
    func testClearingProbesRestoresTheDefault() {
        let watchdog = make(url: nil)
        watchdog.setProbes(["只有一条"], for: "/tmp/proj")
        watchdog.setProbes([], for: "/tmp/proj")

        XCTAssertEqual(watchdog.probeList(for: "/tmp/proj"), SessionWatchdog.defaultProbes)
    }

    func testProbesSurviveRestart() {
        let first = make(url: tempURL)
        first.setProbes(["记住我"], for: "/tmp/proj")

        XCTAssertEqual(make(url: tempURL).probeList(for: "/tmp/proj"), ["记住我"])
    }

    /// 每个项目一份清单，互不干扰。
    func testProbesAreScopedPerProject() {
        let watchdog = make(url: nil)
        watchdog.setProbes(["A 的问题"], for: "/tmp/a")

        XCTAssertEqual(watchdog.probeList(for: "/tmp/b"), SessionWatchdog.defaultProbes)
    }

    // MARK: - 默认清单本身

    /// **默认清单不能只有「继续」。**
    ///
    /// 「继续」能防它停，防不了它每次都继续、每次都做表面功夫。
    /// 观察者的价值在于问它不想被问的那些：落到哪些文件、有哪些卡点没解决。
    func testDefaultProbesAskMoreThanJustContinue() {
        XCTAssertGreaterThan(SessionWatchdog.defaultProbes.count, 3)
        XCTAssertTrue(
            SessionWatchdog.defaultProbes.contains { $0.contains("哪些文件") },
            "必须有一条追问落盘位置——只写结论不落地是最常见的失败形态"
        )
        XCTAssertTrue(
            SessionWatchdog.defaultProbes.contains { $0.contains("卡点") },
            "必须有一条逼它说没做成的部分"
        )
    }

    // MARK: - 历史

    /// 坏掉的配置文件不能让盯梢起不来。
    func testCorruptConfigFallsBackToNothingWatched() throws {
        try "这不是 json".data(using: .utf8)!.write(to: tempURL)

        let watchdog = make(url: tempURL)

        XCTAssertTrue(watchdog.watching.isEmpty)
        XCTAssertFalse(watchdog.probeList(for: "/tmp/proj").isEmpty)
    }
}
