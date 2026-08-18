import CryptoKit
import XCTest
@testable import HubProjects

/// 加密落盘的状态机。
///
/// 这一组几乎每一条都在守同一件事：**「打不开」的时候不许动用户的数据。**
/// `AcceptanceStore.swift:514-518` 记的那次事故（解码失败 → 内存空 → 下次写入覆盖）
/// 在这里的代价是丢线上密码，所以每一条失败路径都要单独钉一遍。
@MainActor
final class EncryptedFileTests: XCTestCase {

    private struct Payload: Codable, Sendable, Equatable {
        var secret: String
    }

    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("vault.dat") }
    private let keyA = SymmetricKey(data: Data(repeating: 0x11, count: 32))
    private let keyB = SymmetricKey(data: Data(repeating: 0x22, count: 32))

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ key: SymmetricKey = SymmetricKey(data: Data(repeating: 0x11, count: 32)),
                      context: String = "creds.v1") -> EncryptedFile<Payload> {
        EncryptedFile<Payload>(url: url, context: context, keys: .fixed(key))
    }

    // MARK: - 正常路径

    func testRoundTrip() throws {
        let a = file()
        XCTAssertNil(a.load())
        XCTAssertEqual(a.state, .empty)
        XCTAssertTrue(a.save(Payload(secret: "hunter2")))

        let b = file()
        XCTAssertEqual(b.load(), Payload(secret: "hunter2"))
        XCTAssertEqual(b.state, .loaded)
    }

    /// 落盘的必须是密文。这条挡的是「某次重构把加密路径短路了」。
    func testFileOnDiskIsCiphertextAndIs600() throws {
        let f = file()
        f.save(Payload(secret: "SENTINEL-DO-NOT-LEAK"))

        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: Data("SENTINEL-DO-NOT-LEAK".utf8)), "明文直接落盘了")

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    }

    /// 备份留的也是密文，权限一样收紧。
    func testBackupIsCiphertextAndIs600() throws {
        let f = file()
        // 哨兵要够长：两三个字节的串在随机密文里本来就会撞上，那样测的是运气不是加密。
        f.save(Payload(secret: "SENTINEL-VERSION-ONE-DO-NOT-LEAK"))
        f.save(Payload(secret: "SENTINEL-VERSION-TWO-DO-NOT-LEAK"))

        let backup = url.appendingPathExtension("hubbak")
        let raw = try Data(contentsOf: backup)
        XCTAssertNil(raw.range(of: Data("SENTINEL-VERSION-ONE-DO-NOT-LEAK".utf8)))
        let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    }

    /// nil url = 不落盘（测试用）。此时一切照常可写，磁盘上什么都不该出现。
    func testNilURLNeverTouchesDisk() {
        let f = EncryptedFile<Payload>(url: nil, context: "creds.v1", keys: .fixed(keyA))
        XCTAssertNil(f.load())
        XCTAssertTrue(f.save(Payload(secret: "x")))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count, 0)
    }

    // MARK: - 钥匙不对：锁住，绝不动文件

    /// **换了一把钥匙 → 锁住，文件原封不动。**
    ///
    /// 这是换机、重装、钥匙串出问题之后最可能出现的状态。
    /// 这里要是走成「当空库」或者「改名」，用户的密码就真的没了 ——
    /// 而他手上的恢复码本来是能救回来的。
    func testWrongKeyLocksAndLeavesFileUntouched() throws {
        file(keyA).save(Payload(secret: "原始数据"))
        let before = try Data(contentsOf: url)

        let f = file(keyB)
        XCTAssertNil(f.load())
        guard case .locked = f.state else { return XCTFail("拿错钥匙没有锁住，state=\(f.state)") }

        XCTAssertEqual(try Data(contentsOf: url), before, "锁住了却改了文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "文件被改名或删了")
    }

    /// 锁住之后**任何写入都必须被挡掉**。这一行 guard 少了，上面那些区分全部白搭。
    func testSaveIsRefusedWhileLocked() throws {
        file(keyA).save(Payload(secret: "原始数据"))
        let before = try Data(contentsOf: url)

        let f = file(keyB)
        _ = f.load()
        XCTAssertFalse(f.save(Payload(secret: "覆盖！")))
        XCTAssertEqual(try Data(contentsOf: url), before, "锁死状态下还是把文件覆盖了")
    }

    /// 钥匙串里根本没有钥匙（换了台机器）—— 同样是锁住，不是「第一次使用」。
    func testMissingKeyLocksInsteadOfStartingFresh() throws {
        file(keyA).save(Payload(secret: "原始数据"))

        let missing = VaultKeySource(
            load: { throw VaultKeychain.Failure.notFound },
            create: { throw VaultKeychain.Failure.notFound }
        )
        let f = EncryptedFile<Payload>(url: url, context: "creds.v1", keys: missing)
        XCTAssertNil(f.load())
        guard case .locked = f.state else { return XCTFail("钥匙没了却没锁住，state=\(f.state)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 文件属于另一个库（复制错了）。它是别处的好数据，**不能改名**。
    func testWrongContextLocksWithoutRenaming() throws {
        EncryptedFile<Payload>(url: url, context: "shared.v1", keys: .fixed(keyA))
            .save(Payload(secret: "共用密钥库的数据"))

        let f = file(keyA, context: "creds.v1")
        XCTAssertNil(f.load())
        guard case .locked = f.state else { return XCTFail("跨库没锁住，state=\(f.state)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "别的库的文件被改名了")
    }

    // MARK: - 文件真坏了：改名保住，不是删掉

    func testCorruptCiphertextIsRescued() throws {
        file(keyA).save(Payload(secret: "原始数据"))
        var raw = try Data(contentsOf: url)
        raw[raw.count - 1] ^= 0xFF
        try raw.write(to: url)

        let f = file(keyA)
        XCTAssertNil(f.load())
        guard case .broken(let rescued) = f.state else {
            return XCTFail("坏文件没进 broken，state=\(f.state)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rescued), "坏文件被删了而不是改名保住")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// 完全不是 vault 的文件也走改名，不能直接覆盖 —— 用户可能只是放错了地方。
    func testForeignFileIsRescuedNotOverwritten() throws {
        try Data("这是别的东西".utf8).write(to: url)
        let f = file(keyA)
        XCTAssertNil(f.load())
        guard case .broken(let rescued) = f.state else { return XCTFail("state=\(f.state)") }
        XCTAssertEqual(try String(contentsOfFile: rescued, encoding: .utf8), "这是别的东西")
    }

    /// broken 之后也不许自动重建 —— 得由界面明确问过用户。
    func testSaveIsRefusedWhileBroken() throws {
        try Data("坏的".utf8).write(to: url)
        let f = file(keyA)
        _ = f.load()
        XCTAssertFalse(f.save(Payload(secret: "新的")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
