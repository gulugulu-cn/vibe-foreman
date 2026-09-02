import XCTest
@testable import HubProjects

/// 「从界面启动项目时 ensure-project-config.sh 永远找不到」（issue #2）。
///
/// 根因：`locateScript` 的候选路径写死在 `~/Documents/code/` 下 ——
/// 仓库克隆在别处、或者用户根本没有仓库（dmg 安装）时三个候选全落空，
/// `ensureProjectConfig` 静默跳过，防污染 deny 和项目级 hook 一条都不补。
/// 而这一步恰好是设计上唯一的那道保险，且失败连日志都没有。
///
/// 修法：scripts/ 由 build-swift-app.sh 打进 .app 的 Contents/Resources/，
/// 候选表优先查 bundle —— 脚本跟二进制一起走，和仓库在磁盘哪个位置解耦。
final class ScriptLocationTests: XCTestCase {

    private let home = "/Users/someone"

    /// bundle 里那份必须排在最前 —— 它是唯一不依赖「仓库克隆在哪」的候选。
    func testBundledScriptComesFirst() {
        let bundle = URL(fileURLWithPath: "/Applications/Vibe Foreman Free.app/Contents/Resources")
        let candidates = TerminalDispatch.scriptCandidates(
            "ensure-project-config.sh", home: home, bundleResourceURL: bundle, environment: [:]
        )
        XCTAssertEqual(
            candidates.first,
            "/Applications/Vibe Foreman Free.app/Contents/Resources/scripts/ensure-project-config.sh"
        )
    }

    /// `CLAUDE_HUB_DIR` 指哪儿就认哪儿 —— 开发者改脚本时不该被 bundle 里
    /// 编译时冻结的那份挡住。GUI app 通常拿不到这个变量，拿到了就是有意的。
    func testExplicitHubDirOverridesBundle() {
        let bundle = URL(fileURLWithPath: "/Applications/X.app/Contents/Resources")
        let candidates = TerminalDispatch.scriptCandidates(
            "ensure-project-config.sh", home: home, bundleResourceURL: bundle,
            environment: ["CLAUDE_HUB_DIR": "/Users/someone/Documents/hengjun/vibe-foreman"]
        )
        XCTAssertEqual(
            candidates.first,
            "/Users/someone/Documents/hengjun/vibe-foreman/scripts/ensure-project-config.sh"
        )
    }

    /// 老用户的三个既有位置一个都不能丢 —— 他们没有 bundle 里的新版之前，
    /// 靠的就是这三条。
    func testLegacyCandidatesAreKept() {
        let candidates = TerminalDispatch.scriptCandidates(
            "ensure-project-config.sh", home: home, bundleResourceURL: nil, environment: [:]
        )
        for expected in [
            "\(home)/Documents/code/vibe-foreman/scripts/ensure-project-config.sh",
            "\(home)/Documents/code/claude-hub/scripts/ensure-project-config.sh",
            "\(home)/.local/share/claude-hub/scripts/ensure-project-config.sh",
        ] {
            XCTAssertTrue(candidates.contains(expected), "丢了既有候选：\(expected)")
        }
    }
}
