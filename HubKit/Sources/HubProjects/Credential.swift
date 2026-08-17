import Foundation
import LocalAuthentication

/// 账号所属的环境。
public enum CredentialEnv: String, Codable, CaseIterable, Sendable, Identifiable {
    case local = "本地"
    case staging = "测试"
    case production = "线上"
    case other = "其它"

    public var id: String { rawValue }

    /// 线上要显眼一点 —— 用错环境的账号去操作是这类工具最容易造成的实际损失。
    public var isProduction: Bool { self == .production }
}

/// 一条账号记录，**不含密码**。
///
/// 密码单独放在 `CredentialStore` 里，只能通过 `password(for:)` 拿，而那条路要过身份验证。
/// 这样拆开不是形式主义：密码要是挂在这个结构体上，将来任何一处
/// `Text(credential.password)` 或者把它塞进日志/导出，都不会有人拦。
public struct Credential: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// `ProjectKey.key(for:)`。nil = 不属于任何项目（比如阿里云控制台这种跨项目的）。
    public var projectKey: String?
    public var env: CredentialEnv
    /// 「线上后台」「测试库 root」。
    public var label: String
    public var username: String
    public var url: String
    public var note: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), projectKey: String? = nil, env: CredentialEnv = .local,
        label: String, username: String = "", url: String = "", note: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectKey = projectKey
        self.env = env
        self.label = label
        self.username = username
        self.url = url
        self.note = note
        self.updatedAt = updatedAt
    }
}

/// 「看一眼」和「复制」之前那道验证。
///
/// 做成可注入的，理由和 `VaultKeySource` 一样：单测不能弹系统对话框，
/// 弹了就再也没法无人值守地跑。
public struct BiometricGate: Sendable {
    public var authenticate: @Sendable (String) async throws -> Void

    public init(authenticate: @escaping @Sendable (String) async throws -> Void) {
        self.authenticate = authenticate
    }

    public enum Failure: Error, Equatable {
        case unavailable(String)
        case denied
    }

    /// Touch ID，没有 Touch ID 的机器上自动退化成开机密码 ——
    /// `.deviceOwnerAuthentication` 本身就包含这个回落，不用自己分支。
    public static let deviceOwner = BiometricGate { reason in
        try await MainActor.run { LAContextHolder.shared }.evaluate(reason: reason)
    }

    /// 测试用。
    public static let alwaysAllow = BiometricGate { _ in }
    public static let alwaysDeny = BiometricGate { _ in throw Failure.denied }
}

/// **同一个 `LAContext` 实例要长期留着。**
///
/// `touchIDAuthenticationAllowableReuseDuration` 只对**这一个实例**生效。
/// 每次验证都 `LAContext()` 新建一个的话，这个设置等于没设 ——
/// 用户每看一条密码就得按一次指纹，很快就会把这个功能关掉。
@MainActor
final class LAContextHolder {
    static let shared = LAContextHolder()

    private var context = LAContextHolder.make()

    private static func make() -> LAContext {
        let c = LAContext()
        c.touchIDAuthenticationAllowableReuseDuration = 300
        c.localizedFallbackTitle = "用开机密码"
        return c
    }

    /// 明确要求重新验证时才换新的（比如用户点了「锁上」）。
    func reset() {
        context.invalidate()
        context = Self.make()
    }

    func evaluate(reason: String) async throws {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw BiometricGate.Failure.unavailable(error?.localizedDescription ?? "系统不支持")
        }
        // 用 continuation 而不是 async 版 API：回调版在所有 SDK 上行为一致，
        // 而这条路一旦在某个系统版本上编不过，密码就再也看不了了。
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, err in
                if ok { cont.resume() } else { cont.resume(throwing: err ?? BiometricGate.Failure.denied) }
            }
        }
    }
}
