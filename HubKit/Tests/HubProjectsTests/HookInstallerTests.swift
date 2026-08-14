import XCTest
@testable import HubProjects

/// 自动安装 hook。
///
/// 用户的话：「零配置」。原来的装法中间夹着一步「双击 dmg 里的安装 hook.command」，
/// 那一步没有任何用户能做的决定，漏了却是**静默失败** —— app 开着、界面正常、
/// 一条事件都收不到。
///
/// 但这段代码会改**用户自己的** `~/.claude/settings.json`，所以边界比功能本身重要：
/// 不许碰他手写的 hook、不许把坏文件覆盖掉、不许每次启动都制造 diff。
final class HookInstallerTests: XCTestCase {

    private func merged(_ settings: [String: Any] = [:]) -> [String: Any] {
        HookInstaller.merge(settings: settings, hubctlPath: "/bin/hubctl")
    }

    private func entries(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return hooks[event] as? [[String: Any]] ?? []
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        entries(settings, event).flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    // MARK: - 装对了吗

    /// **九类全装。** 只装用得着的那几类会让"这一类到底通不通"无从判断 ——
    /// 收不到事件时分不清是没装还是链路断了。设置页的通道健康度靠的就是全装。
    func testInstallsAllNineEvents() {
        let result = merged()
        let hooks = result["hooks"] as? [String: Any] ?? [:]
        XCTAssertEqual(hooks.count, 9, "少装了事件：\(hooks.keys.sorted())")
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "Notification", "Stop", "SubagentStop", "PreCompact", "SessionEnd"] {
            XCTAssertFalse(commands(result, event).isEmpty, "\(event) 没装上")
        }
    }

    /// `PreToolUse` 要等岛上的决策，**必须有 timeout 且大于 hubctl 的 75 秒读超时**。
    /// Claude 若在 hubctl 输出拒绝之前就把它杀掉，等同于没有输出，也就是放行 ——
    /// 正好是安全默认值的反面。
    func testPreToolUseBlocksLongEnough() {
        let entry = entries(merged(), "PreToolUse").first
        let hook = (entry?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(hook?["timeout"] as? Int, 90)
        XCTAssertNil(hook?["async"], "阻塞的 hook 不能是 async")
    }

    /// `Stop` 挡在每一次收工前面，Hub 一卡住用户就干等 —— 上界必须短。
    func testStopHasAShortCeiling() {
        let entry = entries(merged(), "Stop").first
        let hook = (entry?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(hook?["timeout"] as? Int, 10)
    }

    /// 非阻塞的必须 `async: true` —— 同步 hook 会让每轮回复结束都被阻塞几百毫秒。
    func testNonBlockingHooksAreAsync() {
        for event in ["SessionStart", "UserPromptSubmit", "PostToolUse",
                      "Notification", "SubagentStop", "PreCompact", "SessionEnd"] {
            let entry = entries(merged(), event).first
            let hook = (entry?["hooks"] as? [[String: Any]])?.first
            XCTAssertEqual(hook?["async"] as? Bool, true, "\(event) 不是 async")
            XCTAssertNil(hook?["timeout"], "\(event) 不该有 timeout")
        }
    }

    // MARK: - 不许碰用户的东西

    /// **用户手写的 hook 一条都不能丢。** settings.json 是他自己的配置文件。
    func testKeepsUserWrittenHooks() {
        let mine = ["hooks": [["type": "command", "command": "/usr/bin/say done"]]]
        let result = merged(["hooks": ["Stop": [mine]]])
        XCTAssertTrue(
            commands(result, "Stop").contains("/usr/bin/say done"),
            "用户自己的 Stop hook 被删了：\(commands(result, "Stop"))"
        )
    }

    /// settings.json 里别的键（permissions、env 之类）原样保留。
    func testKeepsUnrelatedKeys() {
        let result = merged(["model": "opus", "env": ["A": "1"]])
        XCTAssertEqual(result["model"] as? String, "opus")
        XCTAssertNotNil(result["env"])
    }

    /// 我们自己的旧条目要清掉，否则升级几次之后同一个事件挂着好几份，
    /// 每次工具调用都跑好几遍 hubctl。
    func testReplacesOurOwnPreviousEntries() {
        let old = ["hooks": [["type": "command", "command": "/old/path/hubctl hook stop"]]]
        let result = merged(["hooks": ["Stop": [old]]])
        XCTAssertEqual(commands(result, "Stop").count, 1)
        XCTAssertTrue(commands(result, "Stop")[0].hasPrefix("/bin/hubctl"))
    }

    /// 更早的 bash 版（`hub-hook-stop.sh`）也要清掉。
    func testReplacesLegacyBashHooks() {
        let legacy = ["hooks": [["type": "command", "command": "bash ~/hub-hook-stop.sh"]]]
        let result = merged(["hooks": ["Stop": [legacy]]])
        XCTAssertEqual(commands(result, "Stop").count, 1)
        XCTAssertFalse(commands(result, "Stop")[0].contains("hub-hook-"))
    }

    /// **幂等。** 每次启动都跑一遍，结果必须一模一样 ——
    /// 否则每次开 app 都在用户的配置里制造一个 diff。
    func testMergeIsIdempotent() {
        let once = merged()
        let twice = HookInstaller.merge(settings: once, hubctlPath: "/bin/hubctl")
        XCTAssertEqual(
            NSDictionary(dictionary: once), NSDictionary(dictionary: twice),
            "跑第二遍结果变了"
        )
        XCTAssertEqual(commands(twice, "Stop").count, 1, "重复装出了两份")
    }

    // MARK: - 落盘

    /// 内容没变就一个字节都不写。
    func testSecondRunWritesNothing() throws {
        let (installer, settings, _) = try makeSandbox()

        let first = installer.install()
        XCTAssertTrue(first.isHealthy, "首次安装失败：\(first)")
        let stamp = try FileManager.default
            .attributesOfItem(atPath: settings.path)[.modificationDate] as? Date

        XCTAssertEqual(installer.install(), .alreadyCorrect)
        let after = try FileManager.default
            .attributesOfItem(atPath: settings.path)[.modificationDate] as? Date
        XCTAssertEqual(stamp, after, "内容没变却重写了文件")
    }

    /// **坏 JSON 不许覆盖。** 用户可能只是手改时漏了个逗号，
    /// 覆盖等于把他的配置直接删了。
    func testRefusesToClobberBrokenJSON() throws {
        let (installer, settings, _) = try makeSandbox()
        let broken = "{ \"hooks\": [ oops"
        try broken.write(to: settings, atomically: true, encoding: .utf8)

        let result = installer.install()
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), broken,
                       "坏文件被改动了")
    }

    /// 装完之后自检要认得出来。
    func testHealthCheckPassesAfterInstall() throws {
        let (installer, _, _) = try makeSandbox()
        XCTAssertFalse(installer.isHealthy(), "还没装就说健康")
        _ = installer.install()
        XCTAssertTrue(installer.isHealthy(), "装完了却说不健康")
    }

    /// 造一个沙盒：临时的 settings.json + 临时 bin 目录 + 一个假的 hubctl。
    ///
    /// **绝不能碰真实的 `~/.claude/settings.json`** —— 测试跑一次就把开发机的
    /// hook 配置改了，那比测不到更糟。
    private func makeSandbox() throws -> (HookInstaller, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hookinstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let settings = root.appendingPathComponent("settings.json")
        let bin = root.appendingPathComponent("bin", isDirectory: true)

        // 假的 hubctl。真去 app 包里找的话，xctest 里 Bundle.main 指向测试宿主，
        // 必然落空 —— 那样这几条测试就全变成"测了个找不到文件"。
        let source = root.appendingPathComponent("hubctl")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: source.path
        )

        return (
            HookInstaller(settingsURL: settings, binURL: bin, source: source), settings, bin
        )
    }
}
