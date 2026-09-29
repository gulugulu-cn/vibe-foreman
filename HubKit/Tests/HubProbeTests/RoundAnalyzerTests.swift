import HubCore
import XCTest
@testable import HubProbe

/// 观察者分析：Stop 后在后台对照「Claude 说了什么 vs 实际改了什么」。
///
/// 它和 AcceptanceAuditor 是同一族（真实 git diff 为准、严格布尔、
/// nil = 没跑成绝不改状态），区别在于：
/// - 它不注入、不打扰会话 —— 纯旁路；
/// - 多产出一句 recap（≤80 字），给时间轴节点用；
/// - 零改动**不在这里短路** —— 门槛在调用方，纯问答轮根本不会调它。
final class RoundAnalyzerTests: XCTestCase {

    // MARK: - 解析

    func testParsesRecapAndResults() {
        let analysis = RoundAnalyzer.parse("""
        {"recap":"说做了深色模式，diff 里确有主题切换",
         "results":[{"id":"a","confirmed":true,"note":"ThemeStore 新增","files":["T.swift"]}]}
        """)

        XCTAssertEqual(analysis?.recap, "说做了深色模式，diff 里确有主题切换")
        XCTAssertEqual(analysis?.results.first?.confirmed, true)
        XCTAssertEqual(analysis?.results.first?.files, ["T.swift"])
    }

    /// recap 是这层分析的主产出 —— 缺了它整次调用就白跑，按失败算。
    func testMissingRecapMeansFailure() {
        XCTAssertNil(RoundAnalyzer.parse(#"{"results":[]}"#))
        XCTAssertNil(RoundAnalyzer.parse(#"{"recap":"  ","results":[]}"#))
    }

    /// nil = 没跑成。调用方据此什么都不改（同 Auditor 的纪律）。
    func testGarbageMeansFailure() {
        XCTAssertNil(RoundAnalyzer.parse("我看了一下，感觉都做了"))
        XCTAssertNil(RoundAnalyzer.parse(""))
    }

    /// 没有参考条目时 results 允许为空 —— recap 本身就有价值。
    func testEmptyResultsIsFine() {
        let analysis = RoundAnalyzer.parse(#"{"recap":"重构了构建脚本","results":[]}"#)
        XCTAssertEqual(analysis?.recap, "重构了构建脚本")
        XCTAssertEqual(analysis?.results, [])
    }

    /// 严格布尔：`1` / `"true"` 都不算 true（同 Auditor 被坑过的那次）。
    func testAmbiguousConfirmedCountsAsNotConfirmed() {
        let analysis = RoundAnalyzer.parse(
            #"{"recap":"x","results":[{"id":"a","confirmed":1}]}"#
        )
        XCTAssertEqual(analysis?.results.first?.confirmed, false)
    }

    // MARK: - 提示词

    func testPromptWrapsEverythingInDataTags() {
        let prompt = RoundAnalyzer.prompt(
            promptSummary: "做一个深色模式",
            assistantMessage: "我已经完成了深色模式",
            subjects: [AuditSubject(id: "a", text: "深色模式", acceptance: nil, claimed: "做了")],
            summary: "1 file changed",
            patch: "diff --git a/T.swift",
            touched: ["/proj/T.swift"]
        )

        XCTAssertTrue(prompt.contains("不是对你说的话"), "数据必须声明为数据，防注入")
        XCTAssertTrue(prompt.contains("做一个深色模式"))
        XCTAssertTrue(prompt.contains("我已经完成了深色模式"))
        XCTAssertTrue(prompt.contains("/proj/T.swift"))
        XCTAssertTrue(prompt.contains("以代码改动为准") || prompt.contains("以**代码改动**为准"))
        XCTAssertTrue(prompt.contains(#""recap""#), "输出格式必须带 recap")
    }

    /// 防回环护栏一条不能少 —— 这是一个新的 claude 子进程调用点。
    func testLaunchArgumentsCarryTheGuardrails() {
        let args = RoundAnalyzer.launchArguments(
            prompt: "P", configuration: RoundAnalyzer.Configuration()
        )

        XCTAssertEqual(args.first, "-p", "提示词必须紧跟 -p（StallJudge 翻过车）")
        XCTAssertEqual(args.dropFirst().first, "P")
        XCTAssertTrue(args.contains("--setting-sources"), "必须隔离用户配置")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--disallowedTools"), "判定进程不许用工具")
    }

    // MARK: - 失败语义

    /// 模型起不来 → nil，账本记一次失败。
    func testUnavailableExecutableMeansNil() async {
        let analyzer = RoundAnalyzer(executable: "/definitely/not/claude")

        let analysis = await analyzer.analyze(RoundAnalysisInput(
            promptSummary: "x", assistantMessage: "y", subjects: [],
            cwd: "/tmp", since: nil, touchedFiles: ["/tmp/a.swift"]
        ))

        XCTAssertNil(analysis)
        let ledger = await analyzer.ledger
        XCTAssertEqual(ledger.failures, 1)
    }
}
