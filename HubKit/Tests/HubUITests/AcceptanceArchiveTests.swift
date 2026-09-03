import HubCore
import HubProjects
import XCTest
@testable import HubUI

/// 归档、批量操作与存量迁移。
///
/// 背景（实机截图）：一个项目 496 条「待验收」，发布备忘、编码约定、
/// 一次性操作全躺在里面，永不清理，也没有任何批量操作。
/// 归档 = ledger 内打标（archivedAt），不是删除 —— 可恢复，
/// 且去重继续对全量生效（划掉过的条目不会因归档而复活）。
@MainActor
final class AcceptanceArchiveTests: XCTestCase {

    private var tempDir: URL!
    private let project = "/tmp/archive-project"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ text: String) -> AcceptanceItem {
        AcceptanceItem(text: text, origin: .userPrompt)
    }

    // MARK: - 归档语义

    func testArchivedItemsLeaveEveryActiveSurface() {
        let store = AcceptanceStore(directory: nil)
        let target = item("要归档的")
        store.add(target, to: project)
        store.add(item("留下的"), to: project)

        store.archive(ids: [target.id], in: project)

        let ledger = store.ledger(for: project)
        XCTAssertEqual(ledger.activeItems.map(\.text), ["留下的"])
        XCTAssertEqual(ledger.archivedItems.map(\.text), ["要归档的"])
        XCTAssertEqual(ledger.openCount, 1, "汇报统计只数活跃条目")
        XCTAssertEqual(ledger.items(in: .pending).map(\.text), ["留下的"], "Lane 只显示活跃条目")
        XCTAssertEqual(
            store.injectionText(for: project)?.contains("要归档的"), false,
            "归档条目不许再进注入正文"
        )
    }

    func testUnarchiveRestores() {
        let store = AcceptanceStore(directory: nil)
        let target = item("先归档再恢复")
        store.add(target, to: project)
        store.archive(ids: [target.id], in: project)

        store.unarchive(ids: [target.id], in: project)

        XCTAssertEqual(store.ledger(for: project).activeItems.map(\.text), ["先归档再恢复"])
    }

    /// 归档不是免死金牌：划掉过/归档过的条目再被拆出来一次也不复活。
    func testArchivedItemsStillBlockDuplicates() {
        let store = AcceptanceStore(directory: nil)
        let target = item("加一个深色模式")
        store.add(target, to: project)
        store.archive(ids: [target.id], in: project)

        store.merge([item("加一个深色模式")], into: project)

        let ledger = store.ledger(for: project)
        XCTAssertEqual(ledger.items.count, 1, "归档条目仍参与去重")
        XCTAssertTrue(ledger.activeItems.isEmpty)
    }

    // MARK: - 批量操作

    func testBatchRemoveAndClearLane() {
        let store = AcceptanceStore(directory: nil)
        let a = item("a")
        let b = item("b")
        let c = item("c")
        store.add(a, to: project)
        store.add(b, to: project)
        store.add(c, to: project)

        store.remove(ids: [a.id, b.id], from: project)
        XCTAssertEqual(store.ledger(for: project).items.map(\.text), ["c"])

        store.clear(lane: .pending, in: project)
        XCTAssertTrue(store.ledger(for: project).items.isEmpty)
    }

    func testRemoveAllAndBySession() {
        let store = AcceptanceStore(directory: nil)
        store.add(
            AcceptanceItem(text: "s1 的", origin: .userPrompt, sourceSessionId: "s1"), to: project
        )
        store.add(
            AcceptanceItem(text: "s2 的", origin: .userPrompt, sourceSessionId: "s2"), to: project
        )

        store.removeItems(sessionId: "s1", in: project)
        XCTAssertEqual(store.ledger(for: project).items.map(\.text), ["s2 的"])

        store.removeAll(in: project)
        XCTAssertTrue(store.ledger(for: project).items.isEmpty)
    }

    /// 归档整个 Lane（比如把 130 条「待验收」一键清爽）。
    func testArchiveLane() {
        let store = AcceptanceStore(directory: nil)
        let pending = item("还没做的")
        let done = item("做完的")
        store.add(pending, to: project)
        store.add(done, to: project)
        store.setStatus(.accepted, forID: done.id, in: project)

        store.archive(lane: .pending, in: project)

        let ledger = store.ledger(for: project)
        XCTAssertEqual(ledger.activeItems.map(\.text), ["做完的"])
        XCTAssertEqual(ledger.archivedItems.map(\.text), ["还没做的"])
    }

    // MARK: - 自动过期

    /// 14 天没动静的活跃条目自动归档 —— 没有这条，496 条就是这么攒出来的。
    func testArchiveStaleSweepsOldItems() {
        let store = AcceptanceStore(directory: nil)
        var old = item("三周前的")
        old.updatedAt = Date().addingTimeInterval(-15 * 24 * 3600)
        var fresh = item("昨天的")
        fresh.updatedAt = Date().addingTimeInterval(-1 * 24 * 3600)
        store.add(old, to: project)
        store.add(fresh, to: project)

        store.archiveStale(olderThan: 14)

        let ledger = store.ledger(for: project)
        XCTAssertEqual(ledger.activeItems.map(\.text), ["昨天的"])
        XCTAssertEqual(ledger.archivedItems.map(\.text), ["三周前的"])
    }

    // MARK: - 存量迁移

    /// 老版本的清单（没有 migratedAt）第一次加载时整体归档：
    /// 几百条存量立即从界面清爽，数据可在归档里查看/恢复，时间轴从零开始。
    func testLegacyLedgerIsArchivedOnFirstLoad() throws {
        let url = tempDir.appendingPathComponent(
            UsageStats.encodeDirectoryName(for: project) + ".json"
        )
        let legacy = """
        {"projectPath":"\(project)","rawPrompts":[{"text":"老原话","sessionId":"s","at":1}],
         "items":[{"id":"i1","text":"存量要点","origin":"userPrompt"},
                  {"id":"i2","text":"另一条","origin":"plan","status":"accepted"}]}
        """
        try legacy.data(using: .utf8)!.write(to: url)

        let store = AcceptanceStore(directory: tempDir)

        let ledger = store.ledger(for: project)
        XCTAssertTrue(ledger.activeItems.isEmpty, "存量全部进归档")
        XCTAssertEqual(ledger.archivedItems.count, 2)
        XCTAssertNotNil(ledger.migratedAt)
        XCTAssertTrue(ledger.rawPrompts.isEmpty, "老缓冲不再喂新提取")

        // 幂等：迁移后新加的条目在下一次启动时必须还是活跃的。
        store.add(item("新条目"), to: project)
        let reloaded = AcceptanceStore(directory: tempDir)
        XCTAssertEqual(reloaded.ledger(for: project).activeItems.map(\.text), ["新条目"])
    }
}
