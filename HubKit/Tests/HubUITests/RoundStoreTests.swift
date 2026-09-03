import HubCore
import HubProjects
import XCTest
@testable import HubUI

/// 轮次时间轴的数据层。
///
/// 一「轮」= 用户敲回车（UserPromptSubmit）到 Claude 收工（Stop）。
/// hub 是观察者：轮次记录是**看到什么记什么**，不打扰会话。
@MainActor
final class RoundStoreTests: XCTestCase {

    private var tempDir: URL!
    private let project = "/tmp/round-project"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("round-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 轮次边界

    func testBeginAndCloseMakeOneRound() {
        let store = RoundStore(directory: nil)
        _ = store.beginRound(sessionId: "s1", projectPath: project, prompt: "做一个深色模式")

        let closed = store.closeRound(
            sessionId: "s1", projectPath: project,
            touchedFileCount: 2, hadRealChanges: true, assistantSummary: "改了两个文件"
        )

        XCTAssertNotNil(closed)
        let rounds = store.rounds(for: project)
        XCTAssertEqual(rounds.count, 1)
        XCTAssertEqual(rounds.first?.promptSummary, "做一个深色模式")
        XCTAssertNotNil(rounds.first?.endedAt)
        XCTAssertEqual(rounds.first?.hadRealChanges, true)
        XCTAssertEqual(rounds.first?.touchedFileCount, 2)
    }

    /// Stop 之前用户又说了一句 —— 并进当前未收口的轮，不另开。
    /// （Claude 干活时用户常会补充一句"顺便把 X 也改了"。）
    func testSecondPromptJoinsTheOpenRound() {
        let store = RoundStore(directory: nil)
        let first = store.beginRound(sessionId: "s1", projectPath: project, prompt: "做深色模式")
        let second = store.beginRound(sessionId: "s1", projectPath: project, prompt: "顺便修下字体")

        XCTAssertEqual(first, second, "同会话未收口时不另开轮")
        _ = store.closeRound(
            sessionId: "s1", projectPath: project,
            touchedFileCount: 0, hadRealChanges: false, assistantSummary: nil
        )
        let round = store.rounds(for: project).first
        XCTAssertEqual(round?.promptCount, 2)
        XCTAssertEqual(store.rounds(for: project).count, 1)
    }

    /// 两个会话并行开发同一个项目 —— 各自的轮互不干扰。
    func testParallelSessionsKeepSeparateRounds() {
        let store = RoundStore(directory: nil)
        _ = store.beginRound(sessionId: "a", projectPath: project, prompt: "改 A")
        _ = store.beginRound(sessionId: "b", projectPath: project, prompt: "改 B")

        _ = store.closeRound(
            sessionId: "a", projectPath: project,
            touchedFileCount: 1, hadRealChanges: true, assistantSummary: nil
        )

        let rounds = store.rounds(for: project)
        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds.filter { $0.endedAt != nil }.count, 1, "只有 a 的轮被收口")
    }

    /// Stop 时没有未收口的轮（app 中途才启动）—— 兜底新建再收口，
    /// 时间轴上不能凭空少一轮。
    func testCloseWithoutBeginCreatesAFallbackRound() {
        let store = RoundStore(directory: nil)

        let closed = store.closeRound(
            sessionId: "s1", projectPath: project,
            touchedFileCount: 3, hadRealChanges: true, assistantSummary: "补了三个文件"
        )

        XCTAssertNotNil(closed)
        XCTAssertEqual(store.rounds(for: project).count, 1)
        XCTAssertNotNil(store.rounds(for: project).first?.endedAt)
    }

    /// 长 prompt 截到 120 字上限，换行压成一行。
    func testPromptSummaryIsSingleLineAndCapped() {
        let store = RoundStore(directory: nil)
        let long = String(repeating: "长", count: 200) + "\n第二行"
        _ = store.beginRound(sessionId: "s1", projectPath: project, prompt: long)
        _ = store.closeRound(
            sessionId: "s1", projectPath: project,
            touchedFileCount: 0, hadRealChanges: false, assistantSummary: nil
        )

        let summary = store.rounds(for: project).first?.promptSummary ?? ""
        XCTAssertLessThanOrEqual(summary.count, 121)
        XCTAssertFalse(summary.contains("\n"))
    }

    // MARK: - 分析结果异步补写

    func testApplyAnalysisFillsRecapAndVerdicts() {
        let store = RoundStore(directory: nil)
        let id = store.beginRound(sessionId: "s1", projectPath: project, prompt: "做深色模式")
        _ = store.closeRound(
            sessionId: "s1", projectPath: project,
            touchedFileCount: 1, hadRealChanges: true, assistantSummary: nil
        )

        store.applyAnalysis(
            roundId: id, in: project, recap: "说做了深色模式，diff 里确有主题切换",
            verdicts: [RoundVerdict(itemId: "i1", confirmed: true)],
            diffStat: "2 个文件 +40/-3"
        )

        let round = store.rounds(for: project).first
        XCTAssertEqual(round?.recap, "说做了深色模式，diff 里确有主题切换")
        XCTAssertEqual(round?.verdicts.count, 1)
        XCTAssertEqual(round?.diffStat, "2 个文件 +40/-3")
    }

    /// 轮已经被删/滚掉时补写静默忽略，不炸也不复活。
    func testApplyAnalysisOnRemovedRoundIsIgnored() {
        let store = RoundStore(directory: nil)
        let id = store.beginRound(sessionId: "s1", projectPath: project, prompt: "x")
        _ = store.closeRound(
            sessionId: "s1", projectPath: project,
            touchedFileCount: 0, hadRealChanges: false, assistantSummary: nil
        )
        store.remove(ids: [id], in: project)

        store.applyAnalysis(roundId: id, in: project, recap: "迟到的", verdicts: [], diffStat: nil)

        XCTAssertTrue(store.rounds(for: project).isEmpty)
    }

    // MARK: - 滚动上限与遗留轮

    func testRollsOffBeyondTheCap() {
        let store = RoundStore(directory: nil)
        for index in 0..<(RoundStore.cap + 10) {
            _ = store.beginRound(sessionId: "s\(index)", projectPath: project, prompt: "第 \(index) 轮")
            _ = store.closeRound(
                sessionId: "s\(index)", projectPath: project,
                touchedFileCount: 0, hadRealChanges: false, assistantSummary: nil
            )
        }

        let rounds = store.rounds(for: project)
        XCTAssertEqual(rounds.count, RoundStore.cap)
        XCTAssertEqual(rounds.first?.promptSummary, "第 \(RoundStore.cap + 9) 轮", "留下的是最新的")
    }

    /// app 重启遗留的未收口轮（超过 24h）启动时补收口，别永远显示「进行中」。
    func testStaleOpenRoundsAreClosedOnLoad() throws {
        let first = RoundStore(directory: tempDir)
        _ = first.beginRound(sessionId: "s1", projectPath: project, prompt: "被遗忘的一轮")
        // 把 startedAt 改到 25 小时前（直接改盘上的 JSON，模拟隔夜遗留）。
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        var text = try String(contentsOf: url, encoding: .utf8)
        let old = Date().addingTimeInterval(-25 * 3600).timeIntervalSinceReferenceDate
        text = text.replacingOccurrences(
            of: #""startedAt":[0-9.]+"#, with: "\"startedAt\":\(old)", options: .regularExpression
        )
        try text.write(to: url, atomically: true, encoding: .utf8)

        let reloaded = RoundStore(directory: tempDir)

        XCTAssertNotNil(reloaded.rounds(for: project).first?.endedAt, "隔夜遗留轮要补收口")
    }

    // MARK: - 持久化纪律（照抄 AcceptanceStore 的事故经验）

    func testSurvivesRestart() {
        let first = RoundStore(directory: tempDir)
        _ = first.beginRound(sessionId: "s1", projectPath: project, prompt: "跨重启要还在")
        _ = first.closeRound(
            sessionId: "s1", projectPath: project,
            touchedFileCount: 1, hadRealChanges: true, assistantSummary: nil
        )

        let reloaded = RoundStore(directory: tempDir)

        XCTAssertEqual(reloaded.rounds(for: project).first?.promptSummary, "跨重启要还在")
    }

    /// 老版本写的轮次文件（缺新字段）必须能读出来 —— 同 AcceptanceLedger 的事故。
    func testReadsRoundsWrittenByOlderVersions() throws {
        let url = tempDir.appendingPathComponent(
            UsageStats.encodeDirectoryName(for: project) + ".json"
        )
        let legacy = """
        {"projectPath":"\(project)","rounds":[
          {"id":"r1","sessionId":"s1","projectPath":"\(project)","startedAt":800000000}
        ]}
        """
        try legacy.data(using: .utf8)!.write(to: url)

        let store = RoundStore(directory: tempDir)

        XCTAssertEqual(store.rounds(for: project).first?.id, "r1")
        XCTAssertEqual(store.rounds(for: project).first?.promptCount, 1, "缺失字段要有默认值")
    }

    /// 一条轮坏了不连累其余；解不出来的文件改名保住，不被下一次写入覆盖。
    func testBrokenFileIsRescuedNotOverwritten() throws {
        let url = tempDir.appendingPathComponent(
            UsageStats.encodeDirectoryName(for: project) + ".json"
        )
        try #"{"projectPath":"x","rounds":[{"bro"#.data(using: .utf8)!.write(to: url)

        let store = RoundStore(directory: tempDir)
        _ = store.beginRound(sessionId: "s1", projectPath: project, prompt: "新的一轮")

        let rescued = try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("broken") }
        XCTAssertEqual(rescued.count, 1, "解不出来的原文件必须被保住")
    }
}
