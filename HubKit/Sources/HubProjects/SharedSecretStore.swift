import Foundation
import Observation

/// 共用密钥库。
///
/// 权威副本是**加密**的（`shared-secrets.dat`），明文只存在于
/// `~/.vibe-foreman/env/by-project/*.env` 那几个物化出来的文件里。
///
/// 加密权威副本不是洁癖：不加密的话，`~/Library/Application Support/claude-hub/`
/// 里会躺着一个含**全部**密钥的明文 JSON，AI 一条 `Read` 就整包拿走 ——
/// 那比按项目分装的那些文件糟糕得多，而且用户完全不会想到那里有东西。
/// 加密之后，关掉「物化到磁盘」这个开关就真的等于磁盘上一份明文都没有。
@Observable
@MainActor
public final class SharedSecretStore {

    public private(set) var groups: [SecretGroup] = []
    public private(set) var state: VaultLoadState = .empty
    /// 上一次物化的结果。界面要显示出来 —— 写不进去却不吭声，
    /// 用户会拿着一个内容早就过期的路径去用。
    public private(set) var lastOutcome: EnvMaterializer.Outcome = .alreadyCorrect

    /// 总开关。关掉时清空整个物化目录。
    public var materializeEnabled: Bool = true {
        didSet {
            guard materializeEnabled != oldValue else { return }
            persist()
            reconcile()
        }
    }

    @ObservationIgnored private let file: EncryptedFile<Payload>
    @ObservationIgnored private let root: URL
    /// 上一次拿到的项目列表。物化需要项目名（拼文件名）和 key（查绑定）。
    @ObservationIgnored private var knownProjects: [Project] = []

    private struct Payload: Codable, Sendable {
        var data: SecretVaultData
        var materializeEnabled: Bool
    }

    public nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/shared-secrets.dat")
    }

    /// - Parameters:
    ///   - url: nil = 不落盘。同仓库里其它 store：路径写死会让测试改用户真实数据。
    ///   - root: 物化的根目录。
    ///   - keys: 主密钥来源。测试传 `.fixed(...)`，别去碰真钥匙串。
    public init(
        url: URL? = SharedSecretStore.defaultURL,
        root: URL = EnvMaterializer.defaultRoot,
        keys: VaultKeySource = .keychain
    ) {
        self.file = EncryptedFile<Payload>(url: url, context: "shared.v1", keys: keys)
        self.root = root
        if let payload = file.load() {
            groups = payload.data.groups
            // 绕开 didSet：加载不是「用户改了开关」，不该触发回写和重新物化。
            _materializeEnabled = payload.materializeEnabled
        }
        state = file.state
    }

    // MARK: - 查

    public func groups(for project: Project) -> [SecretGroup] {
        SecretVaultData(groups: groups).groups(forProjectKey: ProjectKey.key(for: project))
    }

    public func isBound(_ group: SecretGroup, to project: Project) -> Bool {
        group.projectKeys.contains(ProjectKey.key(for: project))
    }

    /// 用户要复制的那个路径。
    public func envFilePath(for project: Project) -> String {
        EnvMaterializer.byProjectDirectory(root: root)
            .appendingPathComponent(ProjectKey.envFileName(for: project)).path
    }

    /// 「复制给 AI 的话」按钮的内容。
    ///
    /// **不是裸路径。** 裸路径的下场是 AI 用 `Read` 打开它，于是密钥进
    /// `~/.claude/projects/*.jsonl`（0644、永久、每轮重发），
    /// 而且 Hub 自己的验收清单（`Evidence.ran` 的输出尾巴）也会把它抄一份存下来。
    /// `source` 则只让路径和变量名出现在 transcript 里，值一次都不出现。
    /// 这两句用法和禁令，是「复制路径给 AI」这个交付方式真正管用的版本。
    public func aiPrompt(for project: Project) -> String {
        """
        这个项目要用的平台密钥在 \(envFilePath(for: project))。
        用法：在需要它的那条命令里 `set -a; source '\(envFilePath(for: project))'; set +a; <你的命令>`。
        不要用 Read / cat / grep 打开它，也不要把里面的值写进任何文件或回复。
        """
    }

    public var materializedFileCount: Int {
        EnvMaterializer.materializedFileCount(root: root)
    }

    // MARK: - 改

    @discardableResult
    public func addGroup(name: String, note: String = "") -> SecretGroup {
        let group = SecretGroup(name: name, note: note)
        groups.append(group)
        commit()
        return group
    }

    public func update(_ group: SecretGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        commit()
    }

    public func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        commit()
    }

    public func addEntry(to groupID: UUID, key: String, value: String, note: String = "") {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].entries.append(SecretEntry(key: key, value: value, note: note))
        commit()
    }

    public func update(entry: SecretEntry, in groupID: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == groupID }),
              let e = groups[g].entries.firstIndex(where: { $0.id == entry.id }) else { return }
        groups[g].entries[e] = entry
        commit()
    }

    public func removeEntry(id: UUID, from groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].entries.removeAll { $0.id == id }
        commit()
    }

    public func setBinding(groupID: UUID, project: Project, bound: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let key = ProjectKey.key(for: project)
        if bound { groups[index].projectKeys.insert(key) } else { groups[index].projectKeys.remove(key) }
        commit()
    }

    // MARK: - 物化

    /// 项目列表变了就调一次。物化要靠它拿项目名（拼文件名）和 key（查绑定）。
    public func refresh(projects: [Project]) {
        knownProjects = projects
        reconcile()
    }

    private func commit() {
        persist()
        reconcile()
    }

    private func persist() {
        guard file.save(Payload(data: SecretVaultData(groups: groups),
                                materializeEnabled: materializeEnabled)) else {
            state = file.state
            return
        }
        state = file.state
    }

    private func reconcile() {
        // **锁死/坏文件状态下一个文件都不许碰。**
        //
        // 这时候 `groups` 是空的，但那是「读不出来」不是「没有」。
        // 照常 reconcile 的话，会把用户磁盘上那几份密钥当成「已解绑」全删掉 ——
        // 一次钥匙串抽风就赔进去所有物化文件。
        guard state.canWrite else { return }

        let data = SecretVaultData(groups: groups)
        let byKey = Dictionary(knownProjects.map { (ProjectKey.key(for: $0), $0) },
                               uniquingKeysWith: { first, _ in first })

        var targets: [EnvMaterializer.Target] = []
        for key in data.boundProjectKeys.sorted() {
            // 项目从 projects.yaml 里删掉了，但绑定还在。
            // 不生成文件（没有项目名就没法拼稳定的文件名），旧文件会被 reconcile 清掉 ——
            // 这正是我们要的：项目没了，它的密钥也不该继续躺在磁盘上。
            guard let project = byKey[key] else { continue }
            let fileName = ProjectKey.envFileName(for: project)
            let path = EnvMaterializer.byProjectDirectory(root: root)
                .appendingPathComponent(fileName).path
            targets.append(.init(
                fileName: fileName,
                contents: EnvRenderer.render(
                    groups: data.groups(forProjectKey: key),
                    projectName: project.name,
                    filePath: path
                )
            ))
        }
        lastOutcome = EnvMaterializer.reconcile(targets: targets, root: root,
                                                enabled: materializeEnabled)
    }
}
