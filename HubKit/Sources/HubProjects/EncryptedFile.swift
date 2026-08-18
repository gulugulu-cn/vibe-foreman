import CryptoKit
import Foundation
import HubCore
import os

/// 加密落盘的状态机。共用密钥库和账号密码库都挂在它上面。
public enum VaultLoadState: Equatable, Sendable {
    /// 文件还不存在。第一次用就是这个，可以正常写。
    case empty
    case loaded
    /// **打不开，但数据很可能是好的。** 钥匙串里的主密钥没了、拿到的是另一把、
    /// 或者文件根本不属于这个库。此时禁止一切写入 —— 用户拿恢复码回来还能救。
    case locked(String)
    /// 文件真的坏了，已经改名保住。原位置可以重建。
    case broken(rescuedPath: String)

    public var canWrite: Bool {
        switch self {
        case .empty, .loaded: return true
        case .locked, .broken: return false
        }
    }
}

/// 主密钥从哪来。做成可注入的，单测才不会去碰真的钥匙串 ——
/// `swift test` 的二进制是 ad-hoc 签名的，碰一下就会弹系统授权框，
/// 那样测试就没法在 CI 或者后台跑了。
public struct VaultKeySource: Sendable {
    public var load: @Sendable () throws -> SymmetricKey
    public var create: @Sendable () throws -> SymmetricKey

    public init(
        load: @escaping @Sendable () throws -> SymmetricKey,
        create: @escaping @Sendable () throws -> SymmetricKey
    ) {
        self.load = load
        self.create = create
    }

    public static let keychain = VaultKeySource(
        load: { try VaultKeychain.loadMasterKey() },
        create: { try VaultKeychain.createMasterKey() }
    )

    public static func fixed(_ key: SymmetricKey) -> VaultKeySource {
        VaultKeySource(load: { key }, create: { key })
    }
}

/// 一个加密的 JSON 文件。
///
/// ## 为什么要有 `state`，而不是「解不出来就当空的」
///
/// `AcceptanceStore.swift:514-518` 记着一次真实事故：解码失败 → 内存里是空的 →
/// 下一次写入把几周的数据整个覆盖掉。
///
/// 加密之后，「解不出来」的触发面从「JSON 写坏了」扩大到四种：
/// 写坏了、钥匙串里的钥匙没了、拿到的是另一把钥匙、GCM 认证失败。
/// **大了三倍，而后果从丢验收记录变成丢线上密码。**
///
/// 所以这里把「打不开」拆成两类，处置完全相反：
/// - `locked`：数据大概率是好的 → **一个字节都不动**，等用户拿恢复码回来
/// - `broken`：文件确实坏了 → 改名 `.broken-<时间>` 保住，原位置才允许重建
///
/// 分不出这两类，就必然会在某一次「钥匙不见了」时把好数据当垃圾清掉。
@MainActor
public final class EncryptedFile<Payload: Codable & Sendable> {

    public private(set) var state: VaultLoadState = .empty

    private let url: URL?
    private let context: String
    private let keys: VaultKeySource

    /// - Parameter url: nil = 不落盘。理由同仓库里其它 store：
    ///   路径写死在类型里，测试就会直接读写用户的真实数据。
    public init(url: URL?, context: String, keys: VaultKeySource = .keychain) {
        self.url = url
        self.context = context
        self.keys = keys
        if url == nil { state = .loaded }
    }

    // MARK: - 读

    public func load() -> Payload? {
        guard let url else { state = .loaded; return nil }
        guard let raw = try? Data(contentsOf: url) else { state = .empty; return nil }

        let parsed: VaultCrypto.Parsed
        do {
            parsed = try VaultCrypto.parse(raw)
        } catch {
            // 连文件头都不成形。这不是钥匙的问题。
            state = rescue(url, reason: "\(error)")
            return nil
        }

        let key: SymmetricKey
        do {
            key = try keys.load()
        } catch {
            state = .locked("钥匙串里取不到主密钥（\(error)）。换过机器或重装过系统的话，用恢复码恢复。")
            return nil
        }

        do {
            let plain = try VaultCrypto.open(parsed, using: key, context: context)
            guard let payload = try? JSONDecoder().decode(Payload.self, from: plain) else {
                // 解密成功但内容不认识 —— 版本不兼容或者内容被改过。
                // 密文是好的，所以这是「坏文件」那一档。
                state = rescue(url, reason: "解密成功但内容解析不了")
                return nil
            }
            state = .loaded
            return payload
        } catch VaultCrypto.Failure.wrongKey(let expected, let found) {
            state = .locked("这份数据是另一把钥匙封的（文件 \(expected)，当前 \(found)）。用恢复码换回原来那把。")
            return nil
        } catch VaultCrypto.Failure.wrongContext(let expected, let found) {
            // 不是这个库的文件。**不改名** —— 它是别处的好数据，动它才是事故。
            state = .locked("这个文件属于 \(found)，不是 \(expected)。检查一下是不是复制错了。")
            return nil
        } catch {
            state = rescue(url, reason: "密文认证失败")
            return nil
        }
    }

    // MARK: - 写

    @discardableResult
    public func save(_ payload: Payload) -> Bool {
        // **这一行是整个类型的重点。** 少了它，上面那套状态区分全部白搭。
        guard state.canWrite else { return false }
        guard let url else { return true }

        let key: SymmetricKey
        do {
            // 已经加载过的库必须用原来那把；只有全新的库才允许现造一把。
            // 反过来（load 失败就造新的）会让「钥匙丢了」变成「静默换新钥匙」，
            // 旧密文从此永远打不开，而界面上看起来一切正常。
            if state == .empty {
                key = try (try? keys.load()) ?? keys.create()
            } else {
                key = try keys.load()
            }
        } catch {
            state = .locked("拿不到主密钥（\(error)），已停止写入以免覆盖旧数据。")
            return false
        }

        do {
            let plain = try JSONEncoder().encode(payload)
            let sealed = try VaultCrypto.seal(plain, using: key, context: context)

            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            // 覆盖前留一份上一版的密文。密文备份本身是安全的，可以放心留着。
            // 只留一份、不带时间戳 —— 同 `HookInstaller` 的理由：每次写攒一个
            // 带时间戳的备份，一个月后目录就没法看了。
            if let previous = try? Data(contentsOf: url) {
                let backup = url.appendingPathExtension("hubbak")
                try? previous.write(to: backup, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }

            try sealed.write(to: url, options: .atomic)
            // `.atomic` 换 inode，所以每次写完都要重设一遍，不能只在创建时设。
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            state = .loaded
            return true
        } catch {
            state = .locked("写入失败：\(error)")
            return false
        }
    }

    // MARK: - 救援

    /// 把坏文件改名保住，不是删掉。原位置腾出来才能重建。
    private func rescue(_ url: URL, reason: String) -> VaultLoadState {
        let stamp = BrokenFileStamp.formatter.string(from: Date())
        let rescued = url.appendingPathExtension("broken-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: rescued)
        // 只记文件名和原因，绝不记内容。
        HubLog.app.warning(
            "密钥库文件打不开（\(reason, privacy: .public)），已改名保住：\(rescued.lastPathComponent, privacy: .public)"
        )
        return .broken(rescuedPath: rescued.path)
    }

}

/// 泛型类型里不能放 static 存储属性，所以搬出来单独放。
private enum BrokenFileStamp {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        // 固定 POSIX locale：农历/阿拉伯数字之类的本地化会让文件名变得没法预测。
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
