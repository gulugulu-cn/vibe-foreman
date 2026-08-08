import HubCore
import HubProjects
import XCTest
@testable import HubUI

/// 全部用临时目录。理由同 ApprovalCoordinatorTests：
/// 用默认路径会直接改写用户真实的验收清单。
@MainActor
final class AcceptanceStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acceptance-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private let project = "/tmp/demo-project"

    private func pendingItem(_ text: String = "移动端能正常翻页") -> AcceptanceItem {
        AcceptanceItem(text: text, origin: .userPrompt)
    }

    // MARK: - 上膛：防死循环的核心护栏

    /// **拦截只能由用户上膛，Claude 无法给自己上膛。**
    ///
    /// 这是全案唯一能把用户会话卡死的地方：Stop 拦一次 → Claude 回一轮 → 又 Stop，
    /// 如果那时还能再拦，就是无限循环。
    ///
    /// 这条测试断言的是「连着两次 Stop，第二次必不拦」。它守的不是某个 if 写对了，
    /// 而是 `disarmAndShouldIntercept` 里那句**先卸膛再判断**的顺序 ——
    /// 把 `armedSessions.remove` 删掉或挪到 return 之后，这条必须变红。
    func testOnlyTheUserCanArmInjection() {
        let store = AcceptanceStore(directory: nil)
        store.add(pendingItem(), to: project)

        store.arm(sessionId: "s1")

        XCTAssertTrue(
            store.disarmAndShouldIntercept(sessionId: "s1", projectPath: project),
            "用户说过话且有待办 —— 这一次应该拦"
        )
        XCTAssertFalse(
            store.disarmAndShouldIntercept(sessionId: "s1", projectPath: project),
            "没有新的用户输入就绝不能再拦，否则 Claude 回一轮就触发一次，会话卡死"
        )
    }

    /// 从没上过膛的会话（用户一句话没说）永远不拦。
    func testNeverInterceptsWithoutUserInput() {
        let store = AcceptanceStore(directory: nil)
        store.add(pendingItem(), to: project)

        XCTAssertFalse(store.disarmAndShouldIntercept(sessionId: "never-armed", projectPath: project))
    }

    /// 上膛是按会话隔离的 —— 在 A 会话说话不该让 B 会话被拦。
    func testArmingIsPerSession() {
        let store = AcceptanceStore(directory: nil)
        store.add(pendingItem(), to: project)

        store.arm(sessionId: "a")

        XCTAssertFalse(store.disarmAndShouldIntercept(sessionId: "b", projectPath: project))
        XCTAssertTrue(store.disarmAndShouldIntercept(sessionId: "a", projectPath: project))
    }

    /// 清单为空的项目永远不拦。
    ///
    /// 没启用这功能的项目必须**完全无感** —— 否则装上 Hub 的人会发现
    /// 每个项目收工都被塞一段莫名其妙的东西。
    func testEmptyLedgerNeverIntercepts() {
        let store = AcceptanceStore(directory: nil)
        store.arm(sessionId: "s1")

        XCTAssertFalse(store.disarmAndShouldIntercept(sessionId: "s1", projectPath: project))
        XCTAssertNil(store.injectionText(for: project))
    }

    /// 全部都已经有定论时也不拦。
    func testFullySettledLedgerDoesNotIntercept() {
        let store = AcceptanceStore(directory: nil)
        var item = pendingItem()
        item.status = .accepted
        store.add(item, to: project)
        store.arm(sessionId: "s1")

        XCTAssertFalse(store.disarmAndShouldIntercept(sessionId: "s1", projectPath: project))
    }

    // MARK: - 用户终裁不可被机器覆盖

    /// **用户勾了「接受」之后，旁路复核判什么都不许改回去。**
    ///
    /// 这是对用户的产品承诺（"最终勾选权在你手上"）。没有这条的话，
    /// 用户勾完一转身就被 auditor 打回 disputed，那个勾等于白点。
    func testUserVerdictSurvivesTheAuditor() {
        let store = AcceptanceStore(directory: nil)
        let item = pendingItem()
        store.add(item, to: project)
        store.setStatus(.accepted, forID: item.id, in: project)

        store.applyAudit(
            [AcceptanceVerdict(id: item.id, confirmed: false, note: "diff 里找不到")],
            in: project
        )

        XCTAssertEqual(store.ledger(for: project).items.first?.status, .accepted)
    }

    /// 用户划掉的项同样不许被机器改。
    func testDroppedItemSurvivesTheAuditor() {
        let store = AcceptanceStore(directory: nil)
        let item = pendingItem()
        store.add(item, to: project)
        store.setStatus(.dropped, forID: item.id, in: project)

        store.applyAudit([AcceptanceVerdict(id: item.id, confirmed: true)], in: project)

        XCTAssertEqual(store.ledger(for: project).items.first?.status, .dropped)
    }

    /// 自查回答同样不能覆盖用户终裁。
    func testClaimsCannotOverrideUserVerdict() {
        let store = AcceptanceStore(directory: nil)
        let item = pendingItem()
        store.add(item, to: project)
        store.setStatus(.accepted, forID: item.id, in: project)

        store.applyClaims(
            [AcceptanceClaim(id: item.id, done: true, evidence: "改了 a.swift")], in: project
        )

        XCTAssertEqual(store.ledger(for: project).items.first?.status, .accepted)
    }

    // MARK: - 自述不是证明

    /// **Claude 自报做完，只能推到「待复核」，不能算证明。**
    ///
    /// 这条守的是用户那句"不是说说而已"。`applyClaims` 若把状态直接推到
    /// `.confirmed`、或把证据记成 `.diff` / `.ran`，这条必须变红。
    func testSelfReportIsNeverCountedAsProof() {
        let store = AcceptanceStore(directory: nil)
        let item = pendingItem()
        store.add(item, to: project)

        store.applyClaims(
            [AcceptanceClaim(id: item.id, done: true, evidence: "改了 x.swift，跑了测试")],
            in: project
        )

        let ledger = store.ledger(for: project)
        XCTAssertEqual(ledger.items.first?.status, .claimed, "自报只能到「待复核」")
        XCTAssertFalse(ledger.items.first?.hasProof ?? true, "自述不是证明")
        XCTAssertEqual(ledger.provenCount, 0, "汇报条的「已证」不许把自述算进去")
    }

    /// Hub 自己跑出来的才进「已证」。
    func testOnlyHubProducedEvidenceCounts() {
        let store = AcceptanceStore(directory: nil)
        let item = pendingItem()
        store.add(item, to: project)

        store.applyAudit(
            [AcceptanceVerdict(
                id: item.id, confirmed: true,
                evidence: [.diff(path: "Sources/A.swift", added: 12, removed: 3)]
            )],
            in: project
        )

        XCTAssertEqual(store.ledger(for: project).provenCount, 1)
    }

    /// 它自己承认没做的项要留在「未验收」，别悄悄推进状态。
    func testAdmittedIncompleteStaysOpen() {
        let store = AcceptanceStore(directory: nil)
        let item = pendingItem()
        store.add(item, to: project)

        store.applyClaims(
            [AcceptanceClaim(id: item.id, done: false, evidence: "时间不够，没动")], in: project
        )

        let stored = store.ledger(for: project).items.first
        XCTAssertEqual(stored?.status, .open)
        XCTAssertEqual(stored?.note, "时间不够，没动")
    }

    // MARK: - 注入正文

    func testInjectionTextCarriesIDsAndAcceptanceConditions() {
        let store = AcceptanceStore(directory: nil)
        let item = AcceptanceItem(
            text: "移动端能正常翻页", acceptance: "npm run test:e2e", origin: .plan
        )
        store.add(item, to: project)

        let text = try? XCTUnwrap(store.injectionText(for: project))

        XCTAssertEqual(text?.contains(item.id), true, "没有 id，回答就没法对号入座")
        XCTAssertEqual(text?.contains("移动端能正常翻页"), true)
        XCTAssertEqual(text?.contains("npm run test:e2e"), true)
    }

    /// 注入正文里必须点明「不是你自己列的 todo」。
    ///
    /// 少了这句，Claude 会拿自己的 TodoWrite 来对照 —— 而那份清单正是
    /// 遗漏发生的地方，对照它等于整个功能白做。
    func testInjectionTextDistinguishesItselfFromClaudesOwnTodos() {
        let store = AcceptanceStore(directory: nil)
        store.add(pendingItem(), to: project)

        XCTAssertEqual(store.injectionText(for: project)?.contains("不是你自己列的 todo"), true)
    }

    /// 一次最多摆 6 条，而且**省略了多少必须说出来**。
    ///
    /// 实测在一个真实项目上拦了 12 条，带完整验收条件之后糊了满屏 ——
    /// 要点一多就没人看（Claude 也一样），反而比不拦更容易被忽略。
    /// 静默截断更糟：会让人以为"就这几条"。
    func testInjectionTextIsCappedAndSaysHowManyWereOmitted() {
        let store = AcceptanceStore(directory: nil)
        for index in 0..<12 {
            store.add(AcceptanceItem(text: "要点 \(index)", origin: .userPrompt), to: project)
        }

        let text = store.injectionText(for: project) ?? ""
        let listed = text.split(separator: "\n").filter { $0.hasPrefix("- [") }.count

        XCTAssertEqual(listed, 3)
        XCTAssertTrue(text.contains("另有 9 条未列出"), "省略了多少必须说出来")
    }

    /// **老实回答「没做」不能被惩罚。**
    ///
    /// 答 false 的项保持 `.open`，而 `.open` 正是注入的筛选条件 ——
    /// 不轮换的话每一轮问的都是同一批，后面的要点一次都轮不到。
    /// 实测在我自己身上撞到：连着两轮被问了一模一样的 6 条。
    func testInjectionRotatesInsteadOfAskingTheSameOnesForever() {
        let store = AcceptanceStore(directory: nil)
        for index in 0..<12 {
            store.add(AcceptanceItem(text: "要点 \(index)", origin: .userPrompt), to: project)
        }

        let first = store.injectionText(for: project) ?? ""
        let second = store.injectionText(for: project) ?? ""

        let firstIDs = store.ledger(for: project).items
            .filter { first.contains($0.id) }.map(\.id)
        let secondIDs = store.ledger(for: project).items
            .filter { second.contains($0.id) }.map(\.id)

        XCTAssertEqual(Set(firstIDs).intersection(secondIDs).count, 0, "第二轮该问没问过的那批")
        XCTAssertEqual(secondIDs.count, 3)
    }

    /// 问过 3 次还说没做的，停止再问并标成「疑似误拆」。
    ///
    /// 多半不是它偷懒，是这条要点本身拆偏了（实测真发生过：用户说
    /// 「加个人工确认吧 不然都清理不掉了」被拆成了「清理操作前增加确认步骤」）。
    /// 继续问只是一轮轮浪费，还把真正该问的挤出去。
    func testGivesUpOnItemsAnsweredNotDoneThreeTimes() {
        let store = AcceptanceStore(directory: nil)
        let item = pendingItem("这条大概率拆错了")
        store.add(item, to: project)

        for _ in 0..<3 { _ = store.injectionText(for: project) }

        XCTAssertTrue(store.ledger(for: project).items.first?.likelyMisextracted ?? false)
        XCTAssertNil(store.injectionText(for: project), "问过 3 次就别再问了")
    }

    /// 存疑的必须排在注入正文最前面。
    ///
    /// 那一档是「自报做完但代码里找不到」—— 最该先说清楚的一类，
    /// 排在后面会被 6 条的上限挤掉。
    func testDisputedItemsComeFirstInTheInjection() {
        let store = AcceptanceStore(directory: nil)
        for index in 0..<8 {
            store.add(AcceptanceItem(text: "普通要点 \(index)", origin: .userPrompt), to: project)
        }
        let suspicious = AcceptanceItem(text: "这条自报做了但找不到", origin: .userPrompt)
        store.add(suspicious, to: project)
        store.setStatus(.disputed, forID: suspicious.id, in: project)

        let text = store.injectionText(for: project) ?? ""

        XCTAssertTrue(
            text.contains("这条自报做了但找不到"),
            "存疑项被 6 条上限挤掉了 —— 它恰恰是最该先说的"
        )
    }

    /// 已经有定论的项不该出现在注入正文里。
    func testInjectionTextOmitsSettledItems() {
        let store = AcceptanceStore(directory: nil)
        let done = AcceptanceItem(text: "这条早就做完了", origin: .manual)
        let todo = AcceptanceItem(text: "这条还没做", origin: .manual)
        store.add(done, to: project)
        store.add(todo, to: project)
        store.setStatus(.accepted, forID: done.id, in: project)

        let text = store.injectionText(for: project)

        XCTAssertEqual(text?.contains("这条还没做"), true)
        XCTAssertEqual(text?.contains("这条早就做完了"), false)
    }

    // MARK: - 去重

    func testMergeSkipsDuplicatesRegardlessOfPunctuation() {
        let store = AcceptanceStore(directory: nil)
        store.add(AcceptanceItem(text: "修复 apple-header sticky", origin: .userPrompt), to: project)

        store.merge(
            [AcceptanceItem(text: "修复 apple header sticky。", origin: .plan)], into: project
        )

        XCTAssertEqual(store.ledger(for: project).items.count, 1)
    }

    /// 用户划掉过的要点，不能因为又被拆出来一次就复活。
    func testMergeDoesNotResurrectDroppedItems() {
        let store = AcceptanceStore(directory: nil)
        let item = AcceptanceItem(text: "加一个深色模式", origin: .userPrompt)
        store.add(item, to: project)
        store.setStatus(.dropped, forID: item.id, in: project)

        store.merge([AcceptanceItem(text: "加一个深色模式", origin: .plan)], into: project)

        let ledger = store.ledger(for: project)
        XCTAssertEqual(ledger.items.count, 1)
        XCTAssertEqual(ledger.items.first?.status, .dropped)
    }

    // MARK: - 持久化

    func testSurvivesRestart() {
        let first = AcceptanceStore(directory: tempDir)
        first.add(pendingItem("跨会话要还在"), to: project)

        let reloaded = AcceptanceStore(directory: tempDir)

        XCTAssertEqual(reloaded.ledger(for: project).items.first?.text, "跨会话要还在")
    }

    func testNilDirectoryDoesNotTouchTheDisk() throws {
        let store = AcceptanceStore(directory: nil)
        store.add(pendingItem(), to: project)

        XCTAssertEqual(store.ledger(for: project).items.count, 1, "内存里仍要生效")
        let files = try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }

    /// **外部手改文件后，app 的下一次写入不能把它盖掉。**
    ///
    /// 这条来自一次真实事故：我用脚本往清单文件里写了 9 条要点，而 app 正开着、
    /// 内存里还是旧的一条。app 那边随便点一下，9 条就没了 —— 无声无息。
    /// 清单是给人看也给人改的，手工编辑 JSON 是合理用法，不能是陷阱。
    func testExternalEditsAreNotClobberedByTheNextWrite() throws {
        let store = AcceptanceStore(directory: tempDir)
        store.add(pendingItem("app 加的"), to: project)

        // 模拟"app 开着的时候有人在外面改了文件"
        let external = AcceptanceStore(directory: tempDir)
        external.add(pendingItem("外面加的"), to: project)

        // 第一个 store 内存里还是旧的一条，此时它写一次盘
        store.add(pendingItem("app 后来又加的"), to: project)

        let final = AcceptanceStore(directory: tempDir)
        let texts = final.ledger(for: project).items.map(\.text)
        XCTAssertTrue(texts.contains("外面加的"), "外部改动被盖掉了：\(texts)")
        XCTAssertTrue(texts.contains("app 加的"))
        XCTAssertTrue(texts.contains("app 后来又加的"))
    }

    /// **老版本写的清单（缺新字段）必须能读出来。**
    ///
    /// 这条来自一次真实的数据丢失：给 `AcceptanceLedger` 加了非可选的
    /// `authorizedCommands` 之后，所有已存在的文件当场解码失败 ——
    /// 而读取是 `try?` 静默吞错误的，于是下一次写入从空清单开始，
    /// 把一份 13 条的清单整个覆盖掉，全程无声无息。
    ///
    /// 清单是长期累积的数据，向后兼容不是可选项。
    /// 以后再加字段，这条测试会先红。
    func testReadsLedgersWrittenByOlderVersions() throws {
        let url = tempDir.appendingPathComponent(
            UsageStats.encodeDirectoryName(for: project) + ".json"
        )
        // 一份"老版本"的清单：没有 authorizedCommands，条目里也没有
        // status / evidence / createdAt 这些后来才加的字段。
        let legacy = """
        {"projectPath":"\(project)","rawPrompts":[],"updatedAt":800000000,
         "items":[{"id":"i1","text":"老数据要还在","origin":"userPrompt"}]}
        """
        try legacy.data(using: .utf8)!.write(to: url)

        let store = AcceptanceStore(directory: tempDir)

        XCTAssertEqual(store.ledger(for: project).items.first?.text, "老数据要还在")
        XCTAssertEqual(store.ledger(for: project).items.first?.status, .open, "缺失的字段要有默认值")
        XCTAssertEqual(store.ledger(for: project).authorizedCommands, [])
    }

    /// **一条要点坏了，不能连累同一份清单里其余的。**
    ///
    /// 直接 `decode([AcceptanceItem].self)` 时一条坏的会让整个数组抛错，
    /// 于是整份清单报废 —— 一个项目几十条要点全读不出来。
    /// 同 `TaskStateReader` 的处理：边跑边写的数据，撞上半条是正常情况。
    func testOneBrokenItemDoesNotKillTheRest() throws {
        let url = tempDir.appendingPathComponent(
            UsageStats.encodeDirectoryName(for: project) + ".json"
        )
        // 中间那条缺 text（必填），且 origin 是个没见过的值。
        let mixed = """
        {"projectPath":"\(project)","items":[
          {"id":"a","text":"好的第一条","origin":"userPrompt"},
          {"id":"b","origin":"来自未来的版本"},
          {"id":"c","text":"好的第三条","origin":"manual"}
        ]}
        """
        try mixed.data(using: .utf8)!.write(to: url)

        let store = AcceptanceStore(directory: tempDir)

        XCTAssertEqual(
            store.ledger(for: project).items.map(\.text), ["好的第一条", "好的第三条"],
            "坏的那条跳过就行，不能连累另外两条"
        )
    }

    /// **解不出来的文件绝不能被静默覆盖。**
    ///
    /// 丢数据和读不出来是两个量级的事故。读不出来还能捞回来，
    /// 被覆盖掉就真没了。
    func testUndecodableLedgerIsPreservedNotOverwritten() throws {
        let url = tempDir.appendingPathComponent(
            UsageStats.encodeDirectoryName(for: project) + ".json"
        )
        try #"{"projectPath":"x","items":[{"broken"#.data(using: .utf8)!.write(to: url)

        let store = AcceptanceStore(directory: tempDir)
        store.add(pendingItem("新的一条"), to: project)

        let rescued = try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("broken") }
        XCTAssertEqual(rescued.count, 1, "解不出来的原文件必须被保住，而不是被盖掉")
    }

    /// 单个文件坏掉不能让整个功能失效 —— 清单是边跑边写的，
    /// 撞上半截 JSON 是正常情况。
    func testCorruptFileIsSkippedWithoutLosingTheOthers() throws {
        let good = AcceptanceStore(directory: tempDir)
        good.add(pendingItem("好的那份"), to: project)

        try "这不是 json".data(using: .utf8)!
            .write(to: tempDir.appendingPathComponent("broken.json"))

        let reloaded = AcceptanceStore(directory: tempDir)

        XCTAssertEqual(reloaded.ledger(for: project).items.first?.text, "好的那份")
    }

    // MARK: - 汇报级统计

    func testHeadlineLeadsWithWhatNeedsAttention() {
        let store = AcceptanceStore(directory: nil)
        let disputed = pendingItem("存疑的")
        store.add(disputed, to: project)
        store.add(pendingItem("没做的"), to: project)
        store.setStatus(.disputed, forID: disputed.id, in: project)

        let headline = store.ledger(for: project).headline

        XCTAssertTrue(headline.hasPrefix("存疑 1"), "存疑必须排最前：实际输出是「\(headline)」")
        XCTAssertTrue(headline.contains("未验收 1"))
        XCTAssertTrue(headline.contains("已证 0/2"))
    }

    // MARK: - 导出

    /// 只有自述的项，报告里必须如实写「未经实测验证」。
    ///
    /// 报告是要留档、要发给别人的。把自述渲染得像已验证，
    /// 等于把这个功能要防的问题原样搬进了归档。
    func testReportMarksSelfReportedItemsAsUnverified() {
        let store = AcceptanceStore(directory: nil)
        let item = pendingItem()
        store.add(item, to: project)
        store.applyClaims(
            [AcceptanceClaim(id: item.id, done: true, evidence: "改了 x.swift")], in: project
        )

        let report = store.markdownReport(for: project, projectName: "demo")

        XCTAssertTrue(report.contains("仅自述，未经实测验证"))
    }

    func testReportIncludesCommandOutput() {
        let store = AcceptanceStore(directory: nil)
        let item = pendingItem()
        store.add(item, to: project)
        store.applyAudit(
            [AcceptanceVerdict(
                id: item.id, confirmed: true,
                evidence: [.ran(command: "swift test", exitCode: 0, tail: "265 tests passed")]
            )],
            in: project
        )

        let report = store.markdownReport(for: project, projectName: "demo")

        XCTAssertTrue(report.contains("swift test"))
        XCTAssertTrue(report.contains("265 tests passed"))
    }
}
