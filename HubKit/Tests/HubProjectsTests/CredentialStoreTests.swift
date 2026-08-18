import CryptoKit
import XCTest
@testable import HubProjects

/// 账号密码库。
@MainActor
final class CredentialStoreTests: XCTestCase {

    private var temp: URL!
    private var vaultURL: URL { temp.appendingPathComponent("credentials.dat") }
    private let key = SymmetricKey(data: Data(repeating: 0x44, count: 32))

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-creds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func makeStore(gate: BiometricGate = .alwaysAllow) -> CredentialStore {
        CredentialStore(url: vaultURL, keys: .fixed(key), gate: gate)
    }

    private func sample(_ label: String = "线上后台", env: CredentialEnv = .production,
                        project: String? = "/Users/x/code/hj-admin") -> Credential {
        Credential(projectKey: project, env: env, label: label, username: "admin@example.com")
    }

    // MARK: - 基本

    func testUpsertAndReadBack() async throws {
        let store = makeStore()
        let c = sample()
        XCTAssertTrue(store.upsert(c, password: "Hj#2026abc"))
        let got = try await store.password(for: c.id)
        XCTAssertEqual(got, "Hj#2026abc")
    }

    func testUpdateReplacesInPlace() async throws {
        let store = makeStore()
        var c = sample()
        store.upsert(c, password: "old")
        c.label = "线上后台（新）"
        store.upsert(c, password: "new")

        XCTAssertEqual(store.credentials.count, 1)
        XCTAssertEqual(store.credentials.first?.label, "线上后台（新）")
        let got = try await store.password(for: c.id)
        XCTAssertEqual(got, "new")
    }

    func testRemove() async throws {
        let store = makeStore()
        let c = sample()
        store.upsert(c, password: "x")
        XCTAssertTrue(store.remove(id: c.id))
        XCTAssertTrue(store.credentials.isEmpty)

        do {
            _ = try await store.password(for: c.id)
            XCTFail("删掉之后还能读出密码")
        } catch {
            XCTAssertEqual(error as? CredentialStore.Failure, .notFound)
        }
    }

    func testReloadRestoresEverything() async throws {
        let c = sample()
        do {
            let store = makeStore()
            store.upsert(c, password: "Hj#2026abc")
        }
        let reopened = makeStore()
        XCTAssertEqual(reopened.state, .loaded)
        XCTAssertEqual(reopened.credentials.first?.label, "线上后台")
        let got = try await reopened.password(for: c.id)
        XCTAssertEqual(got, "Hj#2026abc")
    }

    // MARK: - 分组

    func testGroupedByEnvironmentSkipsEmptyBuckets() {
        let store = makeStore()
        store.upsert(sample("线上后台", env: .production), password: "1")
        store.upsert(sample("本地库", env: .local), password: "2")
        store.upsert(sample("别的项目", env: .local, project: "/Users/x/code/geo"), password: "3")

        let groups = store.grouped(projectKey: "/Users/x/code/hj-admin")
        XCTAssertEqual(groups.map(\.env), [.local, .production], "空的环境分组也被列出来了")
        XCTAssertEqual(groups.first(where: { $0.env == .local })?.items.map(\.label), ["本地库"])
    }

    func testOrphansAreItsOwnBucket() {
        let store = makeStore()
        store.upsert(sample("阿里云控制台", env: .other, project: nil), password: "x")
        XCTAssertTrue(store.hasOrphans)
        XCTAssertEqual(store.grouped(projectKey: nil).first?.items.first?.label, "阿里云控制台")
    }

    /// 项目从 projects.yaml 里消失的常见原因是路径改了或者被临时注释掉了。
    /// 跟着删账号是不可逆的 —— 而这里存的是用户唯一一份密码记录。
    func testMissingProjectDetachesInsteadOfDeleting() {
        let store = makeStore()
        let c = sample()
        store.upsert(c, password: "x")

        store.detachCredentials(ofMissingProjectKeys: ["/Users/x/code/hj-admin"])
        XCTAssertEqual(store.credentials.count, 1, "项目没了就把账号删了")
        XCTAssertNil(store.credentials.first?.projectKey)
        XCTAssertTrue(store.hasOrphans)
    }

    // MARK: - 验证

    /// 验证不过就拿不到密码。这道门是「只给人看」的全部实现。
    func testDeniedAuthenticationYieldsNoPassword() async {
        let store = makeStore(gate: .alwaysDeny)
        let c = sample()
        store.upsert(c, password: "Hj#2026abc")

        do {
            _ = try await store.password(for: c.id)
            XCTFail("验证被拒了还是把密码交出去了")
        } catch {
            XCTAssertEqual(error as? BiometricGate.Failure, .denied)
        }
    }

    /// 新增/修改不该问指纹 —— 用户手上本来就有那个密码，再问一遍只是骚扰。
    /// 验证守的是「读出来」，不是「写进去」。
    func testWritingDoesNotRequireAuthentication() {
        let store = makeStore(gate: .alwaysDeny)
        XCTAssertTrue(store.upsert(sample(), password: "x"))
    }

    // MARK: - 落盘与隔离

    func testPasswordNeverAppearsInPlaintextOnDisk() throws {
        let store = makeStore()
        store.upsert(sample(), password: "SENTINEL-CREDENTIAL-DO-NOT-LEAK")

        let raw = try Data(contentsOf: vaultURL)
        XCTAssertNil(raw.range(of: Data("SENTINEL-CREDENTIAL-DO-NOT-LEAK".utf8)))
        XCTAssertNil(raw.range(of: Data("admin@example.com".utf8)))
    }

    /// **这条是整个设计的支点。**
    ///
    /// 两个功能放在同一个 app 里，一个故意要把值写成明文给 AI 用，
    /// 一个绝不能被自动化读到。这条测试用一个真实的哨兵密码跑完整条物化链路，
    /// 断言它一个字节都没漏进给 AI 的那个目录。红了就说明两条路串了。
    func testCredentialPasswordNeverReachesTheSharedEnvDirectory() throws {
        let root = temp.appendingPathComponent("vibe-foreman")
        let sentinel = "SENTINEL-CREDENTIAL-DO-NOT-LEAK"

        let creds = makeStore()
        creds.upsert(sample(), password: sentinel)

        // 同一台机器上共用密钥库照常跑一遍，把该物化的都物化出来。
        let project = Project(name: "hj-admin", path: "~/Documents/code/hj-admin")
        let shared = SharedSecretStore(
            url: temp.appendingPathComponent("shared.dat"), root: root, keys: .fixed(key)
        )
        shared.refresh(projects: [project])
        let g = shared.addGroup(name: "飞书")
        shared.addEntry(to: g.id, key: "FEISHU_APP_ID", value: "cli_abc")
        shared.setBinding(groupID: g.id, project: project, bound: true)
        XCTAssertEqual(shared.materializedFileCount, 1, "物化没跑起来，这条测试就成了空转")

        // 给 AI 的那个目录里，任何一个文件都不许出现这个哨兵。
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        var checked = 0
        while let name = enumerator?.nextObject() as? String {
            let url = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            checked += 1
            XCTAssertNil(data.range(of: Data(sentinel.utf8)),
                         "密码泄进了给 AI 的目录：\(url.path)")
        }
        XCTAssertGreaterThan(checked, 0, "一个文件都没查到，这条测试是空转的")
    }

    /// 锁死状态下写入必须被挡掉，而不是把旧密文覆盖成新的空库。
    func testLockedStoreRefusesWrites() throws {
        do {
            let store = makeStore()
            store.upsert(sample(), password: "原始")
        }
        let before = try Data(contentsOf: vaultURL)

        let otherKey = SymmetricKey(data: Data(repeating: 0x77, count: 32))
        let locked = CredentialStore(url: vaultURL, keys: .fixed(otherKey), gate: .alwaysAllow)
        guard case .locked = locked.state else { return XCTFail("state=\(locked.state)") }

        XCTAssertFalse(locked.upsert(sample("新的"), password: "新"))
        XCTAssertFalse(locked.remove(id: UUID()))
        XCTAssertEqual(try Data(contentsOf: vaultURL), before, "锁死状态下把库覆盖了")
    }

    /// **改备注不该把密码清空。**
    ///
    /// 编辑界面上密码框是空的（要显示原密码得先过验证，改个 URL 还要按指纹太烦），
    /// 所以「没填」必须和「改成空」分开。不分开的话，用户改一下地址就把密码丢了，
    /// 而且要等到下次真的要用的时候才发现。
    func testNilPasswordKeepsTheExistingOne() async throws {
        let store = makeStore()
        var c = sample()
        store.upsert(c, password: "Hj#2026abc")

        c.url = "https://admin.example.com"
        store.upsert(c, password: nil)

        let got = try await store.password(for: c.id)
        XCTAssertEqual(got, "Hj#2026abc")
        XCTAssertEqual(store.credentials.first?.url, "https://admin.example.com")
    }

    /// 但明确填了空字符串就是要清空 —— 那是用户的意思。
    func testEmptyPasswordIsAnExplicitClear() async throws {
        let store = makeStore()
        let c = sample()
        store.upsert(c, password: "x")
        store.upsert(c, password: "")

        let got = try await store.password(for: c.id)
        XCTAssertEqual(got, "")
    }
}
