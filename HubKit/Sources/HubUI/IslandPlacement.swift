import AppKit
import Foundation

/// 岛该待在哪块屏上。
///
/// 以前是写死的「跟着光标跑」，动机是用户在外接屏工作时岛不该留在内建屏、
/// 让他看不见。动机没错，但代价当时没被算清楚：
///
/// 外接屏没有刘海，岛走的是「距屏幕顶悬浮的胶囊」形态，正好压在浏览器标签栏
/// 那一带 —— 命中测试虽然是按形状精确做的，但**那块形状底下本来就有东西**，
/// 于是用户在外接屏上点标签页会点不动。这不是 hit-test 的 bug，是「岛出现在
/// 了一个它不该占位的地方」。
///
/// 所以默认改回**固定在刘海屏**（心智模型：岛长在刘海上，它不该乱跑），
/// 想要跟随的人自己去设置里开。
@MainActor
@Observable
public final class IslandPlacementStore {

    /// 岛是否跟随光标去外接屏。默认 false —— 见类型注释里的点击拦截问题。
    public var followsCursor: Bool = false {
        didSet {
            guard followsCursor != oldValue else { return }
            persist()
            onChange?()
        }
    }

    /// 设置变化后由控制器重新定位。app 层注入。
    @ObservationIgnored
    public var onChange: (() -> Void)?

    /// nonisolated：要当 `init` 的默认参数值用，而默认值在调用方的隔离域里求值。
    public nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/island-placement.json")
    }

    /// nil = 不落盘。必须可注入，理由同 ProjectStore.pinURL：
    /// 路径写死会让测试直接污染用户的真实设置。
    @ObservationIgnored
    private let url: URL?

    public init(url: URL? = IslandPlacementStore.defaultURL) {
        self.url = url
        load()
    }

    /// 当前该用哪块屏。把「设置」翻译成「屏幕」的唯一出口。
    public func screen() -> NSScreen? {
        NotchGeometry.screen(followsCursor: followsCursor)
    }

    // MARK: - 持久化

    private struct Payload: Codable {
        var followsCursor: Bool
    }

    private func load() {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        // 绕开 didSet：加载不是「用户改了设置」，不该触发落盘和重新定位。
        _followsCursor = decoded.followsCursor
    }

    private func persist() {
        guard let url else { return }
        let payload = Payload(followsCursor: followsCursor)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
