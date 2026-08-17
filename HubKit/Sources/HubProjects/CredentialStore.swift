import Foundation
import Observation

/// 账号密码库。
///
/// ## 和共用密钥库的关系：**没有关系，而且必须没有**
///
/// 两个功能长得像（都是「存密码」），但目标相反：
/// 共用密钥库**故意**要把值写成明文文件给 AI 用；这里的密码**只给人看**。
///
/// 所以它们不共用存储、不共用目录，也不共用任何一条写盘路径。
/// 这里的密码只经过 `EncryptedFile`，没有任何代码路径能把它送进 `EnvRenderer`
/// 或 `EnvMaterializer` —— `CredentialStoreTests` 里有一条哨兵测试专门钉这件事。
@Observable
@MainActor
public final class CredentialStore {

    /// 不含密码。密码只能走 `password(for:)`，那条路要过身份验证。
    public private(set) var credentials: [Credential] = []
    public private(set) var state: VaultLoadState = .empty

    @ObservationIgnored private var secrets: [UUID: String] = [:]
    @ObservationIgnored private let file: EncryptedFile<Payload>
    @ObservationIgnored private let gate: BiometricGate

    private struct Record: Codable, Sendable {
        var credential: Credential
        var password: String
    }

    private struct Payload: Codable, Sendable {
        var records: [Record]
    }

    public nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/credentials.dat")
    }

    /// - Parameters:
    ///   - url: nil = 不落盘（测试用）。
    ///   - gate: 查看/复制前的验证。测试传 `.alwaysAllow`，别去弹系统对话框。
    public init(
        url: URL? = CredentialStore.defaultURL,
        keys: VaultKeySource = .keychain,
        gate: BiometricGate = .deviceOwner
    ) {
        self.file = EncryptedFile<Payload>(url: url, context: "creds.v1", keys: keys)
        self.gate = gate
        if let payload = file.load() {
            credentials = payload.records.map(\.credential)
            secrets = Dictionary(payload.records.map { ($0.credential.id, $0.password) },
                                 uniquingKeysWith: { first, _ in first })
        }
        state = file.state
    }

    // MARK: - 查

    /// 某个项目下的账号，按环境分组。`projectKey` 传 nil 拿的是不属于任何项目的那些。
    public func grouped(projectKey: String?) -> [(env: CredentialEnv, items: [Credential])] {
        let mine = credentials.filter { $0.projectKey == projectKey }
        return CredentialEnv.allCases.compactMap { env in
            let items = mine.filter { $0.env == env }.sorted { $0.label < $1.label }
            return items.isEmpty ? nil : (env, items)
        }
    }

    public var usedProjectKeys: [String] {
        Array(Set(credentials.compactMap(\.projectKey))).sorted()
    }

    public var hasOrphans: Bool { credentials.contains { $0.projectKey == nil } }

    /// **拿密码的唯一入口，而且一定要过验证。**
    ///
    /// 不提供一个「不验证也能拿」的旁路 —— 有了那个口子，某处图省事一用，
    /// 这道门就形同虚设，而且从界面上完全看不出来。
    public func password(for id: UUID, reason: String? = nil) async throws -> String {
        guard let value = secrets[id] else { throw Failure.notFound }
        let label = credentials.first { $0.id == id }?.label ?? "这条记录"
        try await gate.authenticate(reason ?? "查看「\(label)」的密码")
        return value
    }

    public enum Failure: Error, Equatable { case notFound, locked }

    // MARK: - 改

    /// 新增/修改都不需要验证 —— 用户手上已经有那个密码了，再问一遍只是骚扰。
    /// 验证守的是「读出来」，不是「写进去」。
    ///
    /// - Parameter password: **nil = 保留原来的密码。**
    ///   编辑界面上密码框是空的（显示原密码要过验证，改个备注还要按指纹太烦），
    ///   所以「没填」必须和「改成空」区分开 —— 不区分的话，用户改一下 URL
    ///   就把密码清空了，而且要等到下次用的时候才发现。
    @discardableResult
    public func upsert(_ credential: Credential, password: String?) -> Bool {
        guard state.canWrite else { return false }
        var updated = credential
        updated.updatedAt = Date()
        if let index = credentials.firstIndex(where: { $0.id == credential.id }) {
            credentials[index] = updated
        } else {
            credentials.append(updated)
        }
        if let password { secrets[credential.id] = password }
        return persist()
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard state.canWrite else { return false }
        credentials.removeAll { $0.id == id }
        secrets[id] = nil
        return persist()
    }

    /// 项目从 projects.yaml 里没了，把它的账号挪成「不属于任何项目」。
    ///
    /// **不删。** 项目从清单里消失的常见原因是路径改了或者临时注释掉了，
    /// 而这里存的是用户唯一一份密码记录 —— 跟着删掉是不可逆的。
    public func detachCredentials(ofMissingProjectKeys missing: Set<String>) {
        guard state.canWrite, !missing.isEmpty else { return }
        var touched = false
        for index in credentials.indices {
            if let key = credentials[index].projectKey, missing.contains(key) {
                credentials[index].projectKey = nil
                touched = true
            }
        }
        if touched { _ = persist() }
    }

    @discardableResult
    private func persist() -> Bool {
        let records = credentials.map {
            Record(credential: $0, password: secrets[$0.id] ?? "")
        }
        let ok = file.save(Payload(records: records))
        state = file.state
        return ok
    }
}
