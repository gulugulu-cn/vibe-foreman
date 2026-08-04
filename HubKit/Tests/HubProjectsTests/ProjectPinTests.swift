import XCTest
@testable import HubProjects

@MainActor
final class ProjectPinTests: XCTestCase {

    // 每个 case 都用临时 pinURL（或 nil）建 store —— 默认路径指向用户真实的
    // ~/Library/Application Support/claude-hub/pinned.json，
    // 测试跑进去既会互相污染，也会往用户数据里写垃圾。

    private func project(_ name: String) -> Project {
        Project(name: name, path: "~/Documents/code/\(name)")
    }

    private func tempPinURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-\(UUID().uuidString).json")
    }

    // MARK: - 状态翻转与持久化

    func testTogglePinFlipsState() {
        let store = ProjectStore(pinURL: nil)
        let target = project("alpha")

        XCTAssertFalse(store.isPinned(target))
        store.togglePin(target)
        XCTAssertTrue(store.isPinned(target))
        store.togglePin(target)
        XCTAssertFalse(store.isPinned(target))
    }

    /// 置顶必须活过重启 —— 只存内存的话每次开 app 都要重新置顶一遍，
    /// 这个功能等于不存在。
    func testPinsSurviveRestart() {
        let url = tempPinURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = ProjectStore(pinURL: url)
        first.togglePin(project("alpha"))
        first.togglePin(project("beta"))
        first.togglePin(project("beta"))   // beta 取消，只剩 alpha

        let reopened = ProjectStore(pinURL: url)
        XCTAssertTrue(reopened.isPinned(project("alpha")))
        XCTAssertFalse(reopened.isPinned(project("beta")))
    }

    func testNilPinURLDoesNotPersist() {
        let store = ProjectStore(pinURL: nil)
        store.togglePin(project("alpha"))
        // 没有落盘位置：新实例什么都读不到（也不该崩）。
        XCTAssertFalse(ProjectStore(pinURL: nil).isPinned(project("alpha")))
    }

    // MARK: - 排序：置顶 > 正在开发 > 最近提交 > 名字

    func testRankPutsPinnedFirstThenRunningThenName() {
        let plain = project("bbb")
        let running = project("ccc")
        let pinnedIdle = project("zzz")

        let ordered = ProjectOrdering.rank(
            [plain, running, pinnedIdle],
            pinned: [pinnedIdle.id],
            runningCount: { $0.id == running.id ? 2 : 0 },
            lastCommitAt: { _ in nil }
        )

        XCTAssertEqual(
            ordered.map(\.name), ["zzz", "ccc", "bbb"],
            "置顶压过运行中，运行中压过名字序"
        )
    }

    /// 最近提交的排前面 —— 这条是「38 个项目里找不到在做的那个」的解药。
    func testRankOrdersIdleProjectsByMostRecentCommit() {
        let old = project("aaa-old")
        let fresh = project("zzz-fresh")
        let middle = project("mmm-mid")
        let dates: [String: Date] = [
            old.id: Date(timeIntervalSince1970: 1_000),
            middle.id: Date(timeIntervalSince1970: 5_000),
            fresh.id: Date(timeIntervalSince1970: 9_000),
        ]

        let ordered = ProjectOrdering.rank(
            [old, fresh, middle], pinned: [],
            runningCount: { _ in 0 },
            lastCommitAt: { dates[$0.id] }
        )

        XCTAssertEqual(ordered.map(\.name), ["zzz-fresh", "mmm-mid", "aaa-old"])
    }

    /// 没有提交记录（新仓 / 读不到 git）的排最后，同档按名字 ——
    /// 列表每 6 秒刷新一次，排序必须稳定，不然行会来回跳。
    func testRankPutsUnknownCommitDatesLastAndStable() {
        let known = project("zzz-known")
        let unknownB = project("bbb-unknown")
        let unknownA = project("aaa-unknown")

        let ordered = ProjectOrdering.rank(
            [unknownB, known, unknownA], pinned: [],
            runningCount: { _ in 0 },
            lastCommitAt: { $0.id == known.id ? Date(timeIntervalSince1970: 1) : nil }
        )

        XCTAssertEqual(ordered.map(\.name), ["zzz-known", "aaa-unknown", "bbb-unknown"])
    }

    /// 正在跑的会话压过"最近提交" —— 此刻在做的事优先级最高。
    func testRunningBeatsRecentCommit() {
        let running = project("aaa-running")
        let recentlyCommitted = project("zzz-recent")

        let ordered = ProjectOrdering.rank(
            [recentlyCommitted, running], pinned: [],
            runningCount: { $0.id == running.id ? 1 : 0 },
            lastCommitAt: { $0.id == recentlyCommitted.id ? Date() : nil }
        )

        XCTAssertEqual(ordered.first?.name, "aaa-running")
    }

    // MARK: - 只提前置顶项（保留能力）

    /// yaml 里的手工分组顺序是用户维护的，置顶只能把置顶项提前，
    /// 不能顺手把其余项目重排。
    func testPinnedFirstIsStablePartition() {
        let list = [project("d"), project("b"), project("c"), project("a")]

        let ordered = ProjectOrdering.pinnedFirst(
            list, pinned: [project("c").id, project("b").id]
        )

        XCTAssertEqual(
            ordered.map(\.name), ["b", "c", "d", "a"],
            "置顶组和未置顶组内部都必须保持传入顺序"
        )
    }

    func testPinnedFirstWithNoPinsReturnsInputOrder() {
        let list = [project("d"), project("b")]
        XCTAssertEqual(
            ProjectOrdering.pinnedFirst(list, pinned: []).map(\.name), ["d", "b"]
        )
    }
}
