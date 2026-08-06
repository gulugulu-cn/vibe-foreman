import XCTest
@testable import HubUI

/// 全部用临时 URL。理由同 ApprovalCoordinatorTests：
/// 用默认路径会直接改写用户真实的设置文件。
@MainActor
final class IslandPlacementTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("island-placement-\(UUID().uuidString).json")
    }

    /// 默认必须是「不跟随」。
    ///
    /// 这条不是风格偏好：跟随光标时岛会跑到外接屏，而外接屏没有刘海，
    /// 岛变成悬浮在屏幕顶部的胶囊，正好压在浏览器标签栏那一带 ——
    /// 底下的东西点不动。默认值改错，用户装上就撞这个坑。
    func testDefaultsToStayingOnTheNotchScreen() {
        XCTAssertFalse(IslandPlacementStore(url: nil).followsCursor)
    }

    func testRemembersTheChoiceAcrossRestarts() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        IslandPlacementStore(url: url).followsCursor = true

        XCTAssertTrue(IslandPlacementStore(url: url).followsCursor)
    }

    func testNilURLDoesNotTouchTheDisk() {
        let store = IslandPlacementStore(url: nil)
        store.followsCursor = true
        // 没有路径可查，能断言的是它不崩、值仍在内存里生效。
        XCTAssertTrue(store.followsCursor)
    }

    /// 改设置要立刻通知控制器挪窗口，否则用户得重启 app 才看得到效果。
    func testChangingTheSettingNotifiesTheController() {
        let store = IslandPlacementStore(url: nil)
        var calls = 0
        store.onChange = { calls += 1 }

        store.followsCursor = true
        XCTAssertEqual(calls, 1)
    }

    /// 设成同一个值不该触发重新定位。
    ///
    /// relocate() 会重建 rootView，而重建会让 SwiftUI 的 @State 归零、
    /// 动画从头开始。设置面板上的 Toggle 每次重绘都可能写回同一个值，
    /// 不挡住的话岛会莫名其妙地闪一下。
    func testWritingTheSameValueIsANoOp() {
        let store = IslandPlacementStore(url: nil)
        var calls = 0
        store.onChange = { calls += 1 }

        store.followsCursor = false
        XCTAssertEqual(calls, 0)
    }

    /// 加载已有设置不算「用户改了设置」—— 不该触发重新定位。
    /// 触发的话 app 每次启动都会在 show() 之外多跑一次 relocate()。
    func testLoadingFromDiskDoesNotFireTheCallback() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        IslandPlacementStore(url: url).followsCursor = true

        let reloaded = IslandPlacementStore(url: url)
        var calls = 0
        reloaded.onChange = { calls += 1 }

        XCTAssertTrue(reloaded.followsCursor)
        XCTAssertEqual(calls, 0, "加载不是用户操作，不该触发重新定位")
    }

    func testCorruptFileFallsBackToTheSafeDefault() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? "这不是 json".data(using: .utf8)!.write(to: url)

        XCTAssertFalse(IslandPlacementStore(url: url).followsCursor)
    }
}
