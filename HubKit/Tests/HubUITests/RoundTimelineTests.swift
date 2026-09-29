import HubCore
import XCTest
@testable import HubUI

/// 时间轴的可测逻辑（分组、节点副标题）。渲染本身不测，规则要测 ——
/// 「进行中 / 分析中 / 纯问答 / 有实改」四种节点必须能一眼分开。
@MainActor
final class RoundTimelineTests: XCTestCase {

    private func round(
        startedAt: Date = Date(),
        endedAt: Date? = Date(),
        hadRealChanges: Bool = false,
        recap: String? = nil,
        diffStat: String? = nil,
        touched: Int = 0
    ) -> RoundRecord {
        RoundRecord(
            sessionId: "s", projectPath: "/p", promptSummary: "x",
            recap: recap, diffStat: diffStat, touchedFileCount: touched,
            hadRealChanges: hadRealChanges, startedAt: startedAt, endedAt: endedAt
        )
    }

    // MARK: - 节点状态行

    func testOpenRoundSaysInProgress() {
        XCTAssertEqual(RoundTimeline.statusLine(for: round(endedAt: nil)), "进行中")
    }

    func testPureChatRoundSaysSo() {
        XCTAssertEqual(RoundTimeline.statusLine(for: round(hadRealChanges: false)), "纯问答")
    }

    /// 有实改但 recap 还没回来 = 分析在后台跑。**必须显示出来** ——
    /// 不显示的话节点看起来就是"没分析"，用户会以为功能坏了。
    func testRealChangesWithoutRecapMeansAnalyzing() {
        XCTAssertEqual(
            RoundTimeline.statusLine(for: round(hadRealChanges: true, recap: nil)), "分析中…"
        )
    }

    func testAnalyzedRoundShowsDiffStat() {
        XCTAssertEqual(
            RoundTimeline.statusLine(for: round(
                hadRealChanges: true, recap: "改了主题", diffStat: "3 个文件 +120/-45"
            )),
            "3 个文件 +120/-45"
        )
    }

    /// diffStat 还没补上时退到 touched 计数，别显示空白。
    func testAnalyzedRoundFallsBackToTouchedCount() {
        XCTAssertEqual(
            RoundTimeline.statusLine(for: round(
                hadRealChanges: true, recap: "改了主题", touched: 2
            )),
            "改了 2 个文件"
        )
    }

    // MARK: - 按天分组

    func testGroupsByDayNewestFirst() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 15))!
        let today = round(startedAt: now.addingTimeInterval(-3600))
        let yesterday = round(startedAt: now.addingTimeInterval(-26 * 3600))
        let older = round(startedAt: now.addingTimeInterval(-70 * 3600))

        let groups = RoundTimeline.groupByDay(
            [today, yesterday, older], calendar: calendar, now: now
        )

        XCTAssertEqual(groups.map(\.label), ["今天", "昨天", "8月31日"])
        XCTAssertEqual(groups[0].rounds.count, 1)
    }
}
