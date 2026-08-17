import CryptoKit
import Foundation

/// 本地静态加密。密码库和共用密钥库都用它。
///
/// ## 文件布局
///
/// ```
/// "VFV1" | UInt32BE(headerLen) | headerBytes | AES-GCM.combined
/// ```
///
/// `headerBytes` 明文可读（里面没有秘密，只有 keyID 和 context），
/// 但它同时是 GCM 的 AAD —— 改一个字节，解密就失败。
///
/// ## 三条不能动的规矩
///
/// **1. AAD 用文件里存的那段原始字节，永远不重新序列化。**
/// 如果 AAD 是「把 header 结构体再 encode 一遍得到的字节」，那么 Swift 版本升级、
/// `Date` 编码策略变化、字典键序变化 —— 任何一个都会让**所有历史文件永久打不开**。
/// 这是 `HookInstaller` 那句「`.sortedKeys` 不是审美，是幂等的前提」的加密版，
/// 但后果严重一个量级：那边是每隔几次启动无意义改一次用户文件，这边是数据再也拿不回来。
///
/// **2. nonce 每次随机生成，绝不在文件里存计数器。**
/// 文件是可以被回滚的（Time Machine、手动复制旧备份、git checkout）。
/// 计数器一旦回滚就会重用 nonce，而 GCM 的 nonce 重用不只是泄密 ——
/// 它会让攻击者能**伪造**密文。随机 96-bit nonce 在「整库重写、一天几十次」
/// 的量级下碰撞概率可以忽略。
///
/// **3. `parse` 和 `open` 必须分开调用。**
/// 「钥匙不对」和「文件坏了」的处置**完全相反**：
/// 钥匙不对时数据是好的，绝不能改名或覆盖，只能锁住等用户拿恢复码回来；
/// 文件坏了才该改名保命（同 `AcceptanceStore` 的 `.broken-<ts>`）。
/// 分不出这两种情况，就必然会在某一次「解不开」时把好数据当垃圾清掉。
/// header 里的 `keyID` 就是为了分出这两种情况才存在的。
public enum VaultCrypto {

    /// 魔数。四个字节，用来一眼认出「这根本不是我们的文件」。
    static let magic = Data("VFV1".utf8)

    public struct Header: Codable, Equatable, Sendable {
        public var version: Int
        /// 封它的那把钥匙的指纹。**这个字段是整个设计的关键**，理由见类型注释第 3 条。
        public var keyID: String
        /// `shared.v1` / `creds.v1`。进 AAD，所以把密钥库的密文塞进密码库解不开。
        /// 两边格式一模一样，混了不会报错，只会解出一堆语义不对的东西 —— 那是静默的。
        public var context: String

        public init(version: Int = 1, keyID: String, context: String) {
            self.version = version
            self.keyID = keyID
            self.context = context
        }
    }

    public struct Parsed: Sendable {
        public let header: Header
        /// **原样保留的字节**，`open` 时直接拿它当 AAD。见类型注释第 1 条。
        public let headerBytes: Data
        public let payload: Data
    }

    public enum Failure: Error, Equatable {
        /// 魔数不对：这不是 vault 文件（用户放错了、或者路径撞了别的东西）。
        case notAVault
        /// 长度不够，读不完整。
        case truncated
        /// header 解不出来。
        case badHeader
        /// context 不匹配：拿密码库的钥匙去开密钥库这种。
        case wrongContext(expected: String, found: String)
        /// **钥匙不对，但文件很可能是好的。** 收到它绝不能删、不能改名、不能覆盖。
        case wrongKey(expected: String, found: String)
        /// keyID 对上了但 GCM 认证失败 —— 密文被改过或截断了。这才是真的坏文件。
        case corrupt
    }

    // MARK: - 密钥指纹

    /// 钥匙的公开指纹。只用来判断「是不是同一把」，从它推不回密钥。
    public static func keyID(for key: SymmetricKey) -> String {
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) })
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 封

    public static func seal(_ plaintext: Data, using key: SymmetricKey, context: String) throws -> Data {
        let header = Header(keyID: keyID(for: key), context: context)
        // `.sortedKeys` 在这里不是为了幂等（AAD 用的是存下来的字节，编码稳不稳定都无所谓），
        // 而是为了让人 `xxd` 看文件头的时候字段顺序是固定的，排障时少一个变量。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headerBytes = try encoder.encode(header)

        let box = try AES.GCM.seal(plaintext, using: key, authenticating: headerBytes)
        guard let combined = box.combined else { throw Failure.corrupt }

        var out = magic
        withUnsafeBytes(of: UInt32(headerBytes.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(headerBytes)
        out.append(combined)
        return out
    }

    // MARK: - 拆

    /// 只解 header。成功不代表能解开内容 —— 那是 `open` 的事。
    public static func parse(_ raw: Data) throws -> Parsed {
        // Data 的切片保留原始索引（`data[4..<8]` 在 startIndex != 0 时会越界崩）。
        // 重新构造一份把索引拉回 0，是这里唯一安全的写法。
        let data = Data(raw)
        guard data.count >= 8 else { throw Failure.truncated }
        guard data.prefix(4) == magic else { throw Failure.notAVault }

        let headerLen = Int(data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian
        })
        // headerLen 来自文件，可能是垃圾。先卡上界再切，否则一个坏字节就能让我们
        // 去切一个 4 GB 的范围。
        guard headerLen > 0, data.count >= 8 + headerLen else { throw Failure.truncated }

        let headerBytes = Data(data[8..<(8 + headerLen)])
        guard let header = try? JSONDecoder().decode(Header.self, from: headerBytes) else {
            throw Failure.badHeader
        }
        return Parsed(header: header, headerBytes: headerBytes, payload: Data(data[(8 + headerLen)...]))
    }

    public static func open(_ parsed: Parsed, using key: SymmetricKey, context: String) throws -> Data {
        guard parsed.header.context == context else {
            throw Failure.wrongContext(expected: context, found: parsed.header.context)
        }
        let id = keyID(for: key)
        // **先比 keyID 再尝试解密。** 顺序反过来的话，钥匙不对和文件损坏都只会得到
        // 一个 `AES.GCM` 的 authenticationFailure，上层就分不出该锁住还是该改名。
        guard parsed.header.keyID == id else {
            throw Failure.wrongKey(expected: parsed.header.keyID, found: id)
        }
        guard let box = try? AES.GCM.SealedBox(combined: parsed.payload),
              let plain = try? AES.GCM.open(box, using: key, authenticating: parsed.headerBytes)
        else {
            throw Failure.corrupt
        }
        return plain
    }

    public static func open(_ raw: Data, using key: SymmetricKey, context: String) throws -> Data {
        try open(parse(raw), using: key, context: context)
    }
}
