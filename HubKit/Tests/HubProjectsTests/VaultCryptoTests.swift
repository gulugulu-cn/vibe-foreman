import CryptoKit
import XCTest
@testable import HubProjects

/// 加密底座的边界。
///
/// 这一组测试守的不是「加密对不对」（CryptoKit 的事），而是**解不开的时候
/// 上层能不能分辨出该锁住还是该改名**。分辨不出来，就一定会在某一次
/// 「钥匙不见了」时把好数据当垃圾清掉 —— 那正是 `AcceptanceStore.swift:514-518`
/// 记的那次事故，只不过后果从丢验收记录变成丢线上密码。
final class VaultCryptoTests: XCTestCase {

    private let keyA = SymmetricKey(data: Data(repeating: 0xA1, count: 32))
    private let keyB = SymmetricKey(data: Data(repeating: 0xB2, count: 32))
    private let plain = Data("FEISHU_APP_SECRET=abc123".utf8)

    func testRoundTrip() throws {
        let sealed = try VaultCrypto.seal(plain, using: keyA, context: "creds.v1")
        XCTAssertEqual(try VaultCrypto.open(sealed, using: keyA, context: "creds.v1"), plain)
    }

    /// **密文里不许出现明文。** 这条看着像废话，但它是唯一能挡住
    /// 「某次重构把加密路径短路成了直接落盘」的测试。
    func testCiphertextContainsNoPlaintext() throws {
        let sealed = try VaultCrypto.seal(plain, using: keyA, context: "creds.v1")
        XCTAssertNil(sealed.range(of: plain))
    }

    /// nonce 每次新生成，所以同一份明文两次封出来的密文不同。
    /// 相同就说明 nonce 被固定或被复用了 —— GCM 的 nonce 重用不只是泄密，
    /// 它让攻击者能伪造密文。
    func testNonceIsNotReused() throws {
        let a = try VaultCrypto.seal(plain, using: keyA, context: "creds.v1")
        let b = try VaultCrypto.seal(plain, using: keyA, context: "creds.v1")
        XCTAssertNotEqual(a, b)
    }

    /// **钥匙不对 ≠ 文件坏了。** 这是整个类型存在的理由。
    /// 拿错钥匙时必须报 `wrongKey`，上层据此进「锁死」状态、保住文件；
    /// 如果这里退化成 `corrupt`，上层就会去改名甚至重建，用户的密码就没了。
    func testWrongKeyIsDistinguishableFromCorruption() throws {
        let sealed = try VaultCrypto.seal(plain, using: keyA, context: "creds.v1")
        XCTAssertThrowsError(try VaultCrypto.open(sealed, using: keyB, context: "creds.v1")) {
            guard case VaultCrypto.Failure.wrongKey = $0 else {
                return XCTFail("拿错钥匙报成了 \($0)，上层会把好数据当坏文件处理")
            }
        }
    }

    /// keyID 对上了但内容被改过 —— 这才是真的坏文件。
    func testTamperedPayloadIsCorrupt() throws {
        var sealed = try VaultCrypto.seal(plain, using: keyA, context: "creds.v1")
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try VaultCrypto.open(sealed, using: keyA, context: "creds.v1")) {
            XCTAssertEqual($0 as? VaultCrypto.Failure, .corrupt)
        }
    }

    /// **AAD 生效的证明。** header 不参与认证的话，攻击者可以随便改 version、
    /// 改 context、将来改 slot 参数，而密文照样解得开。
    func testTamperedHeaderFailsAuthentication() throws {
        var sealed = try VaultCrypto.seal(plain, using: keyA, context: "creds.v1")
        // 改 header 的一个字节，但保持 JSON 仍然可解析、keyID 和 context 都不动 ——
        // 改那两个会分别触发 wrongKey / wrongContext，测的就是别的东西了。
        // 精确框出 header 的范围，不要顺手扫到密文里去。
        let headerEnd = try 8 + VaultCrypto.parse(sealed).headerBytes.count
        guard let versionPos = sealed[8..<headerEnd].range(of: Data("\"version\":1".utf8)) else {
            return XCTFail("header 里找不到 version 字段，测试前提变了")
        }
        sealed[versionPos.upperBound - 1] = UInt8(ascii: "2")
        XCTAssertThrowsError(try VaultCrypto.open(sealed, using: keyA, context: "creds.v1")) {
            XCTAssertEqual($0 as? VaultCrypto.Failure, .corrupt)
        }
    }

    /// 两个库的文件格式一模一样。context 不进 AAD 的话，
    /// 把 `shared-secrets.dat` 复制成 `credentials.dat` 会「成功」解开，
    /// 然后解出一堆语义不对的东西 —— 而且是静默的。
    func testContextMismatchIsRejected() throws {
        let sealed = try VaultCrypto.seal(plain, using: keyA, context: "shared.v1")
        XCTAssertThrowsError(try VaultCrypto.open(sealed, using: keyA, context: "creds.v1")) {
            guard case VaultCrypto.Failure.wrongContext = $0 else {
                return XCTFail("跨库解密报成了 \($0)")
            }
        }
    }

    /// 不是我们的文件要一眼认出来，不能当成「坏了的 vault」去改名 ——
    /// 那会把用户放错位置的别的文件改名。
    func testForeignFileIsNotAVault() {
        XCTAssertThrowsError(try VaultCrypto.parse(Data("{\"hello\":1}".utf8))) {
            XCTAssertEqual($0 as? VaultCrypto.Failure, .notAVault)
        }
    }

    /// headerLen 是从文件里读出来的，可能是垃圾。
    /// 不卡上界的话，一个坏字节就能让我们去切一个 4 GB 的范围然后崩掉。
    func testAbsurdHeaderLengthIsTruncatedNotCrash() {
        var data = VaultCrypto.magic
        withUnsafeBytes(of: UInt32(0xFFFF_FFFF).bigEndian) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 0, count: 16))
        XCTAssertThrowsError(try VaultCrypto.parse(data)) {
            XCTAssertEqual($0 as? VaultCrypto.Failure, .truncated)
        }
    }

    func testEmptyAndTinyFiles() {
        XCTAssertThrowsError(try VaultCrypto.parse(Data()))
        XCTAssertThrowsError(try VaultCrypto.parse(Data([0x56, 0x46])))
    }

    /// 指纹只是用来判断「是不是同一把」，不能反推密钥，也不能两把不同的钥匙撞成一个。
    func testKeyIDIsStableAndDistinct() {
        XCTAssertEqual(VaultCrypto.keyID(for: keyA), VaultCrypto.keyID(for: keyA))
        XCTAssertNotEqual(VaultCrypto.keyID(for: keyA), VaultCrypto.keyID(for: keyB))
    }
}
