import CryptoKit
import Foundation
import Security

/// 主密钥的家。两个库（共用密钥、账号密码）共用这一把。
///
/// ## 为什么是一把主密钥，而不是每条密码一个 Keychain item
///
/// 不是为了少弹窗 —— 恰恰相反，**弹窗就是这里唯一的那道防线**，见下。
/// 真实理由有三个：legacy `SecItem*` 存结构化数据只能往 password 字段塞 JSON，
/// 等于自己重写一遍序列化；分组、排序、「本地/线上」这些 UI 状态照样得落一个附属文件，
/// 两份数据不同步是迟早的事；而且整库原子写会丢掉。
///
/// ## `kSecAttrAccess` 绝对不能传
///
/// `SecItemAdd` 不传 `kSecAttrAccess` 时，默认 ACL 是「只有创建它的那个 app
/// 能无提示读取」，别人读会弹系统授权框。
///
/// 在「攻击者 = 跟你同一个 uid 跑的自动化」这个威胁模型下，
/// **能区分「Vibe Foreman 在读」和「`security find-generic-password` 在读」的只有这个 ACL。**
/// 文件权限做不到（同一个 uid，0600 形同虚设）；Touch ID 也做不到
/// （`LAContext` 只是一道 UI 门，它不参与密钥的取用）。
///
/// 所以一旦有人为了「消掉那个烦人的弹窗」改成 `SecAccessCreate` + 空信任列表，
/// Claude Code 一条 Bash 就能取走主密钥，然后五行脚本解开整个密码库 ——
/// 这个功能的安全性会当场归零，而且外观上完全看不出来。
///
/// ## 弹窗的真实频率取决于签名
///
/// ACL 里存的是 designated requirement，不是二进制哈希 —— 前提是**有证书**：
///
/// | 签名方式 | ACL 记的是 | 重新编译之后 |
/// |---|---|---|
/// | `Claude Hub Dev` 自签名证书 | bundle id + 证书指纹，**不含 cdhash** | 不失效，不弹 |
/// | ad-hoc（`codesign --sign -`） | 含 **cdhash** | 每次失效，每次弹 |
///
/// `scripts/build-swift-app.sh` 的注释里早就写了自签名证书让「TCC 授权在每次重新编译后
/// 仍然有效」—— TCC 和 Keychain ACL 用的是同一套匹配逻辑。这个仓库一直在依赖这个机制，
/// 只是以前没意识到它同样管钥匙串。所以 `isAdHocSigned()` 要在界面上如实说出来，
/// 不静默降级成「每次都弹一下」让用户以为是 bug。
public enum VaultKeychain {

    public static let service = "dev.hengjun.claude-hub"
    public static let account = "vault-master-key-v1"

    public enum Failure: Error, Equatable {
        /// 钥匙串里没有这一项。首次使用是正常的；**用过之后再出现就是事故**
        /// （换机、重装、keychain reset），此时绝不能当成「空库」重新开始。
        case notFound
        case badRecoveryCode
        case os(OSStatus)
    }

    // MARK: - 取用

    public static func loadMasterKey(service: String = service) throws -> SymmetricKey {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw Failure.notFound }
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            throw Failure.os(status)
        }
        return SymmetricKey(data: data)
    }

    @discardableResult
    public static func createMasterKey(service: String = service) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        try store(key, service: service)
        return key
    }

    /// **只在明确知道「库里本来就没东西」时才调它。**
    /// 不要在 store 的 load 路径上用 —— 那样「钥匙串里的钥匙不见了」会被当成
    /// 「第一次使用」，静默生成一把新的，然后旧密文永远打不开而界面看起来一切正常。
    public static func loadOrCreateMasterKey(service: String = service) throws -> SymmetricKey {
        do { return try loadMasterKey(service: service) } catch Failure.notFound {
            return try createMasterKey(service: service)
        }
    }

    private static func store(_ key: SymmetricKey, service: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        var attrs = baseQuery(service: service)
        attrs[kSecValueData as String] = data
        // 授权框里显示的名字。用户看到「某个 app 想访问 xxx」时得知道 xxx 是什么。
        attrs[kSecAttrLabel as String] = "Vibe Foreman 密码库主密钥"
        attrs[kSecAttrDescription as String] = "删掉它，app 里保存的密钥和账号密码将无法解密"
        // 这里**刻意不传 kSecAttrAccess**，保留默认 ACL。理由见类型注释。

        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(service: service) as CFDictionary,
                                             update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw Failure.os(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw Failure.os(status) }
    }

    public static func deleteMasterKey(service: String = service) throws {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.os(status)
        }
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - 恢复码

    /// 主密钥本身的 base32。
    ///
    /// 主密钥会丢，而且场景一点都不罕见：改登录密码之后点了「新建钥匙串」、
    /// 换 Mac 时迁移助理没带上钥匙串、从 Time Machine 只恢复了
    /// `~/Library/Application Support/`（因为那看起来才是「app 的数据」）、
    /// 为了修别的毛病跑过一次 keychain reset。
    ///
    /// 而这份数据的定位是「人的记忆的最后一道备份」。它丢了，用户是真的进不去线上系统。
    /// 所以恢复码不是加分项，是这个功能能不能上线的前提。
    ///
    /// 选恢复码而不是「设一个主口令」：CryptoKit 没有 PBKDF2，走 CommonCrypto 要多一整套
    /// 派生 + 盐 + 迭代数的代码和迁移格式，而两者提供的恢复保证是一样的。
    /// 恢复码还有个额外好处 —— 它天生就该被丢进用户已有的密码管理器，而不是靠记。
    public static func recoveryCode(service: String = service) throws -> String {
        let key = try loadMasterKey(service: service)
        return Base32.encode(key.withUnsafeBytes { Data($0) })
    }

    @discardableResult
    public static func restore(fromRecoveryCode code: String, service: String = service) throws -> SymmetricKey {
        guard let data = Base32.decode(code), data.count == 32 else { throw Failure.badRecoveryCode }
        let key = SymmetricKey(data: data)
        try store(key, service: service)
        return key
    }

    // MARK: - 签名自检

    /// 当前进程是不是 ad-hoc 签名。是的话每次重新编译都会重新弹钥匙串授权。
    ///
    /// 判据是**有没有证书链**，不是别的：ad-hoc 签名（`codesign --sign -`）没有证书，
    /// 于是 designated requirement 只能退化成 cdhash，而 cdhash 每次编译都变。
    public static func isAdHocSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return false }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return false }

        let certs = dict[kSecCodeInfoCertificates as String] as? [Any]
        return (certs ?? []).isEmpty
    }
}
