import HubCore
import HubProjects
import XCTest
@testable import HubUI

/// 从验收清单当场生成的追问。
///
/// 手写的通用清单问几轮之后就被摸清套路了，答案会越来越像模板。
/// 而清单里明明躺着十几条待验收、几条存疑 —— **那些才是该问的具体问题**，
/// 而且每一条都问不出模板答案。
@MainActor
final class GeneratedProbeTests: XCTestCase {

    private let project = "/tmp/proj"

    private func make(_ items: [AcceptanceItem]) -> SessionWatchdog {
        let acceptance = AcceptanceStore(directory: nil)
        for item in items { acceptance.add(item, to: project) }
        return SessionWatchdog(
            store: SessionStore(),
            projects: ProjectStore(yamlURL: nil, pinURL: nil),
            acceptance: acceptance,
            url: nil
        )
    }

    /// 追问里必须带上要点原文 —— 不带的话它根本不知道在问哪一条。
    func testAsksAboutTheActualItem() {
        let watchdog = make([AcceptanceItem(text: "移动端能正常翻页", origin: .userPrompt)])

        let probes = watchdog.generatedProbes(for: project)

        XCTAssertEqual(probes.count, 1)
        XCTAssertTrue(probes[0].contains("移动端能正常翻页"))
    }

    /// 有验收条件就一并给出 —— 省得它反问"怎么算做到"。
    func testIncludesTheAcceptanceCondition() {
        let watchdog = make([
            AcceptanceItem(text: "跑通测试", acceptance: "swift test", origin: .plan),
        ])

        XCTAssertTrue(watchdog.generatedProbes(for: project)[0].contains("swift test"))
    }

    /// **存疑的必须排最前。**
    ///
    /// 那一档是「它自报做完了、但真实 diff 里找不到」—— 整个清单里最该
    /// 当面对质的一类。排在后面会被 12 条的上限挤掉。
    func testDisputedItemsComeFirst() {
        let acceptance = AcceptanceStore(directory: nil)
        for index in 0..<15 {
            acceptance.add(AcceptanceItem(text: "普通 \(index)", origin: .userPrompt), to: project)
        }
        let suspicious = AcceptanceItem(text: "这条自报做了但找不到", origin: .userPrompt)
        acceptance.add(suspicious, to: project)
        acceptance.setStatus(.disputed, forID: suspicious.id, in: project)

        let watchdog = SessionWatchdog(
            store: SessionStore(), projects: ProjectStore(yamlURL: nil, pinURL: nil),
            acceptance: acceptance, url: nil
        )

        XCTAssertTrue(
            watchdog.generatedProbes(for: project)[0].contains("这条自报做了但找不到"),
            "存疑的被挤掉了 —— 它恰恰是最该当面问的"
        )
    }

    /// 存疑项的问法要点明「你说做完了但找不到」，不能和普通待验收一个口吻。
    func testDisputedProbeConfrontsTheClaim() {
        let acceptance = AcceptanceStore(directory: nil)
        let item = AcceptanceItem(text: "加了深色模式", origin: .userPrompt)
        acceptance.add(item, to: project)
        acceptance.setStatus(.disputed, forID: item.id, in: project)

        let watchdog = SessionWatchdog(
            store: SessionStore(), projects: ProjectStore(yamlURL: nil, pinURL: nil),
            acceptance: acceptance, url: nil
        )

        let probe = watchdog.generatedProbes(for: project)[0]
        XCTAssertTrue(probe.contains("你说做完了"))
        XCTAssertTrue(probe.contains("找不到"))
    }

    /// 已经有定论的不该再问。
    func testSettledItemsAreNotAsked() {
        let acceptance = AcceptanceStore(directory: nil)
        let done = AcceptanceItem(text: "早就做完了", origin: .userPrompt)
        acceptance.add(done, to: project)
        acceptance.setStatus(.accepted, forID: done.id, in: project)

        let watchdog = SessionWatchdog(
            store: SessionStore(), projects: ProjectStore(yamlURL: nil, pinURL: nil),
            acceptance: acceptance, url: nil
        )

        XCTAssertTrue(watchdog.generatedProbes(for: project).isEmpty)
    }

    /// 「疑似误拆」的也不该再问 —— 它已经被判定为拆错了。
    func testMisextractedItemsAreNotAsked() {
        let acceptance = AcceptanceStore(directory: nil)
        acceptance.add(AcceptanceItem(text: "这条拆错了", origin: .userPrompt), to: project)
        for _ in 0..<3 { _ = acceptance.injectionText(for: project) }

        let watchdog = SessionWatchdog(
            store: SessionStore(), projects: ProjectStore(yamlURL: nil, pinURL: nil),
            acceptance: acceptance, url: nil
        )

        XCTAssertTrue(watchdog.generatedProbes(for: project).isEmpty)
    }

    /// 超长要点要截断 —— 注入有长度和单行限制，整段贴进去会被拒发。
    func testLongItemsAreTruncated() {
        let long = String(repeating: "很长的要点", count: 30)
        let watchdog = make([AcceptanceItem(text: long, origin: .userPrompt)])

        let probe = watchdog.generatedProbes(for: project)[0]
        XCTAssertLessThan(probe.count, 160)
        XCTAssertFalse(probe.contains(where: \.isNewline), "有换行会被注入那层拒发")
    }

    // MARK: - 通用与清单交替

    /// **两边交替。** 只问清单会让它一直在对答案，只问通用又摸不到具体的漏项。
    func testAlternatesBetweenGenericAndGenerated() {
        let watchdog = make([AcceptanceItem(text: "具体的那一条", origin: .userPrompt)])
        watchdog.setProbes(["通用问题"], for: project)

        XCTAssertEqual(watchdog.nextProbe(for: project, sessionId: "s1"), "通用问题")
    }

    /// 清单为空时全走通用，不能因此哑掉。
    func testFallsBackToGenericWhenLedgerIsEmpty() {
        let watchdog = make([])
        watchdog.setProbes(["通用问题"], for: project)

        XCTAssertEqual(watchdog.nextProbe(for: project, sessionId: "s1"), "通用问题")
    }
}
