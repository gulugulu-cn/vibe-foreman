import CryptoKit
import XCTest
@testable import HubProjects

/// 共用密钥库端到端：改一条 → 落密文盘 → 物化成 `.env`。
@MainActor
final class SharedSecretStoreTests: XCTestCase {

    private var temp: URL!
    private var vaultURL: URL { temp.appendingPathComponent("shared-secrets.dat") }
    private var root: URL { temp.appendingPathComponent("vibe-foreman") }
    private let key = SymmetricKey(data: Data(repeating: 0x33, count: 32))

    private let hjAdmin = Project(name: "hj-admin", path: "~/Documents/code/hj-admin")
    private let geo = Project(name: "geo-design", path: "~/Documents/code/geo-design")

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func makeStore() -> SharedSecretStore {
        SharedSecretStore(url: vaultURL, root: root, keys: .fixed(key))
    }

    private func envText(_ project: Project, _ store: SharedSecretStore) -> String? {
        try? String(contentsOfFile: store.envFilePath(for: project), encoding: .utf8)
    }

    // MARK: - 端到端

    func testBoundGroupIsMaterializedAndUnboundIsNot() throws {
        let store = makeStore()
        store.refresh(projects: [hjAdmin, geo])
        let feishu = store.addGroup(name: "飞书")
        store.addEntry(to: feishu.id, key: "FEISHU_APP_ID", value: "cli_abc")
        store.setBinding(groupID: feishu.id, project: hjAdmin, bound: true)

        XCTAssertTrue(envText(hjAdmin, store)?.contains("export FEISHU_APP_ID='cli_abc'") == true)
        XCTAssertNil(envText(geo, store), "没绑定的项目也被生成了文件")
    }

    /// 解绑之后磁盘上那份必须真的消失。留着的话用户以为收回了，实际路径还在、值还在。
    func testUnbindingRemovesTheFile() throws {
        let store = makeStore()
        store.refresh(projects: [hjAdmin])
        let g = store.addGroup(name: "领星")
        store.addEntry(to: g.id, key: "LINGXING_KEY", value: "k")
        store.setBinding(groupID: g.id, project: hjAdmin, bound: true)
        XCTAssertNotNil(envText(hjAdmin, store))

        store.setBinding(groupID: g.id, project: hjAdmin, bound: false)
        XCTAssertNil(envText(hjAdmin, store))
    }

    /// 删组连带删绑定 —— 绑定挂在组身上就是为了这个。
    func testRemovingGroupDropsItsBindings() throws {
        let store = makeStore()
        store.refresh(projects: [hjAdmin])
        let g = store.addGroup(name: "OpenAI")
        store.addEntry(to: g.id, key: "OPENAI_API_KEY", value: "sk-x")
        store.setBinding(groupID: g.id, project: hjAdmin, bound: true)

        store.removeGroup(id: g.id)
        XCTAssertNil(envText(hjAdmin, store))
        XCTAssertEqual(EnvMaterializer.materializedFileCount(root: root), 0)
    }

    /// 一个项目绑了两组，两组的变量都要在同一个文件里。
    func testMultipleGroupsMergeIntoOneFile() throws {
        let store = makeStore()
        store.refresh(projects: [hjAdmin])
        let a = store.addGroup(name: "飞书")
        let b = store.addGroup(name: "领星")
        store.addEntry(to: a.id, key: "FEISHU_APP_ID", value: "1")
        store.addEntry(to: b.id, key: "LINGXING_KEY", value: "2")
        store.setBinding(groupID: a.id, project: hjAdmin, bound: true)
        store.setBinding(groupID: b.id, project: hjAdmin, bound: true)

        let text = envText(hjAdmin, store) ?? ""
        XCTAssertTrue(text.contains("FEISHU_APP_ID"))
        XCTAssertTrue(text.contains("LINGXING_KEY"))
        XCTAssertEqual(EnvMaterializer.materializedFileCount(root: root), 1)
    }

    /// **一个项目的文件里只能有它自己绑的东西。**
    ///
    /// 这不构成安全边界（同 uid 下 `cat ../别的.env` 照样拿得到），
    /// 但它决定了「复制给 AI 的那个路径」里装的是不是只有它该知道的部分。
    func testProjectFileContainsOnlyItsOwnGroups() throws {
        let store = makeStore()
        store.refresh(projects: [hjAdmin, geo])
        let a = store.addGroup(name: "飞书")
        let b = store.addGroup(name: "阿里云")
        store.addEntry(to: a.id, key: "FEISHU_APP_ID", value: "1")
        store.addEntry(to: b.id, key: "ALIYUN_SECRET", value: "2")
        store.setBinding(groupID: a.id, project: hjAdmin, bound: true)
        store.setBinding(groupID: b.id, project: geo, bound: true)

        XCTAssertFalse(envText(hjAdmin, store)?.contains("ALIYUN_SECRET") == true)
        XCTAssertFalse(envText(geo, store)?.contains("FEISHU_APP_ID") == true)
    }

    // MARK: - 落盘

    /// 权威副本是密文。不加密的话这里会躺着一个含全部密钥的明文 JSON，
    /// AI 一条 Read 就整包拿走。
    func testVaultOnDiskIsEncrypted() throws {
        let store = makeStore()
        let g = store.addGroup(name: "飞书")
        store.addEntry(to: g.id, key: "K", value: "SENTINEL-VAULT-PLAINTEXT-CHECK")

        let raw = try Data(contentsOf: vaultURL)
        XCTAssertNil(raw.range(of: Data("SENTINEL-VAULT-PLAINTEXT-CHECK".utf8)))
        XCTAssertNil(raw.range(of: Data("飞书".utf8)))
    }

    func testReloadRestoresGroupsAndBindings() throws {
        do {
            let store = makeStore()
            store.refresh(projects: [hjAdmin])
            let g = store.addGroup(name: "飞书", note: "开放平台")
            store.addEntry(to: g.id, key: "FEISHU_APP_ID", value: "cli_abc", note: "自建应用")
            store.setBinding(groupID: g.id, project: hjAdmin, bound: true)
        }
        let reopened = makeStore()
        XCTAssertEqual(reopened.state, .loaded)
        XCTAssertEqual(reopened.groups.count, 1)
        XCTAssertEqual(reopened.groups.first?.entries.first?.value, "cli_abc")
        XCTAssertTrue(reopened.isBound(reopened.groups[0], to: hjAdmin))
    }

    // MARK: - 总开关

    func testDisablingMaterializationClearsDiskButKeepsData() throws {
        let store = makeStore()
        store.refresh(projects: [hjAdmin])
        let g = store.addGroup(name: "飞书")
        store.addEntry(to: g.id, key: "FEISHU_APP_ID", value: "cli_abc")
        store.setBinding(groupID: g.id, project: hjAdmin, bound: true)

        store.materializeEnabled = false
        XCTAssertEqual(store.materializedFileCount, 0, "关掉开关之后磁盘上还有明文")
        XCTAssertEqual(store.groups.first?.entries.first?.value, "cli_abc", "数据被一起删了")

        store.materializeEnabled = true
        XCTAssertTrue(envText(hjAdmin, store)?.contains("cli_abc") == true)
    }

    func testMaterializeToggleSurvivesReload() throws {
        do {
            let store = makeStore()
            store.materializeEnabled = false
        }
        XCTAssertFalse(makeStore().materializeEnabled)
    }

    // MARK: - 锁死

    /// **钥匙不对的时候，一个物化文件都不许动。**
    ///
    /// 这时 `groups` 是空的，但那是「读不出来」不是「没有」。
    /// 照常 reconcile 会把磁盘上那几份密钥当「已解绑」全删掉 ——
    /// 钥匙串抽一次风就赔进去所有物化文件。
    func testLockedStoreDoesNotWipeMaterializedFiles() throws {
        do {
            let store = makeStore()
            store.refresh(projects: [hjAdmin])
            let g = store.addGroup(name: "飞书")
            store.addEntry(to: g.id, key: "FEISHU_APP_ID", value: "cli_abc")
            store.setBinding(groupID: g.id, project: hjAdmin, bound: true)
        }
        XCTAssertEqual(EnvMaterializer.materializedFileCount(root: root), 1)

        let otherKey = SymmetricKey(data: Data(repeating: 0x99, count: 32))
        let locked = SharedSecretStore(url: vaultURL, root: root, keys: .fixed(otherKey))
        locked.refresh(projects: [hjAdmin])

        guard case .locked = locked.state else { return XCTFail("state=\(locked.state)") }
        XCTAssertEqual(EnvMaterializer.materializedFileCount(root: root), 1,
                       "锁死状态下把用户的物化文件清掉了")
    }

    // MARK: - 给 AI 的那段话

    /// **必须是 source 契约，不能是裸路径。**
    ///
    /// 裸路径的下场是 AI 用 `Read` 打开它，密钥进
    /// `~/.claude/projects/*.jsonl`（0644、永久、每轮重发给 API），
    /// 而且 Hub 自己的验收清单（`Evidence.ran` 的输出尾巴）也会抄一份存下来。
    func testAIPromptTellsItToSourceNotRead() {
        let store = makeStore()
        let prompt = store.aiPrompt(for: hjAdmin)
        XCTAssertTrue(prompt.contains("set -a; source"))
        XCTAssertTrue(prompt.contains("不要用 Read"))
        XCTAssertTrue(prompt.contains(store.envFilePath(for: hjAdmin)))
    }

    /// 项目从 projects.yaml 里删了，它的密钥不该继续躺在磁盘上。
    func testVanishedProjectLosesItsFile() throws {
        let store = makeStore()
        store.refresh(projects: [hjAdmin])
        let g = store.addGroup(name: "飞书")
        store.addEntry(to: g.id, key: "K", value: "v")
        store.setBinding(groupID: g.id, project: hjAdmin, bound: true)
        XCTAssertEqual(store.materializedFileCount, 1)

        store.refresh(projects: [])
        XCTAssertEqual(store.materializedFileCount, 0)
    }
}
