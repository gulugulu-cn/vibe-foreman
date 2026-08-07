import Foundation
import Observation

/// 「Hub 自己跑验收命令」的总开关。
///
/// 单独一个类型、单独一个文件，而不是塞进 `AcceptanceStore`：
/// 这是全案唯一控制**执行命令**的开关，它值得一眼就能找到，
/// 也不该和几百条验收要点混在同一份 JSON 里 —— 那份文件是会被手改的。
///
/// **默认关闭。** 用户装上 Hub 时不该有任何东西在背后跑命令。
@Observable
@MainActor
public final class VerifierSettings {

    public var enabled: Bool = false {
        didSet {
            guard enabled != oldValue else { return }
            persist()
            onChange?(enabled)
        }
    }

    /// 开关变化后通知 verifier actor。app 层注入。
    @ObservationIgnored
    public var onChange: ((Bool) -> Void)?

    /// nonisolated：要当 `init` 的默认参数值用，默认值在调用方的隔离域里求值。
    /// 同 `IslandPlacementStore.defaultURL`。
    public nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/verifier.json")
    }

    /// nil = 不落盘。理由同仓库里其它几个 store：
    /// 路径写死会让测试直接改用户的真实设置。
    @ObservationIgnored
    private let url: URL?

    public init(url: URL? = VerifierSettings.defaultURL) {
        self.url = url
        load()
    }

    private struct Payload: Codable {
        var enabled: Bool
    }

    private func load() {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        // 绕开 didSet：加载不是「用户改了设置」，不该触发回写和回调。
        _enabled = decoded.enabled
    }

    private func persist() {
        guard let url else { return }
        guard let data = try? JSONEncoder().encode(Payload(enabled: enabled)) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
