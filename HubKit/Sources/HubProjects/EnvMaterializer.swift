import Foundation

/// 把共用密钥落成磁盘上的 `.env` 文件。
///
/// 形状抄 `HookInstaller`：路径可注入、返回 `Outcome` 不抛异常、内容零差异就一个字节都不写、
/// 另有一个只读的体检入口给界面用。**但 `.hubbak` 那一行不要抄** ——
/// 那里写备份连 `.atomic` 都没有，用在 hook 配置上无所谓，用在密钥上不行。
///
/// ## 目录长这样
///
/// ```
/// ~/.vibe-foreman/                    drwx------
/// ├── .vf-owned                       (没有它就不敢删这里的任何东西)
/// ├── .metadata_never_index           (尽力挡一下 Spotlight)
/// └── env/by-project/
///     └── hj-admin-9f3a1c8d.env       -rw-------
/// ```
///
/// 放在家目录下而不是 `~/Library/Application Support/`，唯一理由是**这个路径要被复制粘贴**。
///
/// ## 「按项目一个文件」是分装，不是隔离
///
/// 所有文件同一个 uid、同样 0600，项目 A 的会话 `cat ../B-xxxx.env` 一秒就拿到。
/// 它降低的是**误取**的概率（AI 拿到的路径里只有它该知道的东西），
/// 不构成任何安全边界。真边界要靠 PreToolUse hook，那是另一件事。
/// 界面文案上不要写成「项目 A 拿不到项目 B 的密钥」。
public enum EnvMaterializer {

    public enum Outcome: Equatable {
        /// 磁盘上已经是对的，一个字节都没写。
        case alreadyCorrect
        case installed(written: Int, removed: Int)
        /// 总开关关掉了，已清空。
        case cleared(removed: Int)
        /// 出事了，**并且什么都没写**。
        case failed(String)

        public var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    public struct Target: Equatable, Sendable {
        public let fileName: String
        public let contents: String
        public init(fileName: String, contents: String) {
            self.fileName = fileName
            self.contents = contents
        }
    }

    public nonisolated static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe-foreman", isDirectory: true)
    }

    static let ownerMarker = ".vf-owned"
    static let spotlightMarker = ".metadata_never_index"

    public static func byProjectDirectory(root: URL) -> URL {
        root.appendingPathComponent("env/by-project", isDirectory: true)
    }

    // MARK: - 主入口

    /// 让磁盘和 `targets` 对齐。多的删掉，少的补上，一样的不动。
    ///
    /// - Parameter enabled: 总开关。关掉时清空整个目录并返回 `.cleared`。
    ///
    /// 三个调用时机：绑定/内容变更时、app 启动时（补上崩溃那次漏掉的删除）、
    /// 用户手动点「清空」时。
    @discardableResult
    public static func reconcile(
        targets: [Target],
        root: URL = defaultRoot,
        enabled: Bool = true
    ) -> Outcome {
        let fm = FileManager.default
        let wanted = enabled ? targets : []

        // 没东西要物化、目录也还不存在 —— 什么都别做。
        //
        // 启动时会无条件对一次账（补崩溃时漏掉的删除），要是这里照常建目录，
        // 那么**每个装了这个 app 的人家目录里都会凭空多出一个 `~/.vibe-foreman`**，
        // 哪怕他从来没用过这个功能。工具不该在你还没用它的时候就往你家里放东西。
        if wanted.isEmpty, !fm.fileExists(atPath: root.path) {
            return .alreadyCorrect
        }

        // 每一次都查，不是启动时查一次 —— 用户完全可能过一阵子才在 $HOME 里
        // `git init`（chezmoi / yadm / 手搓 dotfiles 越来越常见），
        // 那之后再往这里写就等于把全部密钥推上 GitHub。
        if let repo = enclosingGitRepository(of: root) {
            return .failed("\(root.path) 在 git 仓库 \(repo.path) 里，已拒绝写入密钥")
        }

        do {
            try claimRoot(root)
        } catch {
            return .failed("准备 \(root.path) 失败：\(error.localizedDescription)")
        }

        let dir = byProjectDirectory(root: root)
        let wantedNames = Set(wanted.map(\.fileName))

        var removed = 0
        var written = 0

        // 1) 删掉不该再存在的。**只删自己生成的那个形状的文件**，
        //    用户往这个目录里放的东西一个都不碰。
        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in existing where ProjectKey.looksLikeGeneratedEnvFile(name) && !wantedNames.contains(name) {
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
        }

        // 2) 写该存在的。
        for target in wanted {
            let url = dir.appendingPathComponent(target.fileName)
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current == target.contents {
                // 内容对了也要确认权限 —— 用户或者别的工具可能 chmod 过。
                // 只改权限不动内容，mtime 不变，幂等判断照样成立。
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                continue
            }
            guard let data = target.contents.data(using: .utf8) else { continue }
            do {
                try data.write(to: url, options: .atomic)
                // **必须每次写完都设一遍。** `.atomic` 是「写临时文件再 rename」，
                // 临时文件按 umask 建（通常 0644），rename 之后 inode 就换了 ——
                // 上一次 chmod 是设在旧 inode 上的，跟这个新文件没关系。
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                written += 1
            } catch {
                return .failed("写 \(target.fileName) 失败：\(error.localizedDescription)")
            }
        }

        if !enabled { return .cleared(removed: removed) }
        if written == 0, removed == 0 { return .alreadyCorrect }
        return .installed(written: written, removed: removed)
    }

    // MARK: - 只读体检

    /// 界面上那句「当前有 N 个项目的密钥在磁盘上」。
    ///
    /// 独立于 `reconcile`：进页面只是想看看现状，不该顺手改文件。
    /// 同 `HookInstaller.isHealthy()` 的道理。
    public static func materializedFileCount(root: URL = defaultRoot) -> Int {
        let dir = byProjectDirectory(root: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter(ProjectKey.looksLikeGeneratedEnvFile).count
    }

    // MARK: - 零件

    /// 建目录、认领它、放好两个标记文件。
    ///
    /// **目录的 0700 才是真正承重的那道。** 文件的 0600 有个短暂的窗口不成立：
    /// `.atomic` 先按 umask 建临时文件再 rename，那一瞬间它是 0644。
    /// 目录不可进入的话，那一瞬间对别的用户也没有意义。
    private static func claimRoot(_ root: URL) throws {
        let fm = FileManager.default
        let marker = root.appendingPathComponent(ownerMarker)

        if fm.fileExists(atPath: root.path), !fm.fileExists(atPath: marker.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            if !contents.isEmpty {
                // 这个目录里有东西但不是我们建的。接管它就意味着 reconcile 会去删里面的文件。
                throw Error.notOurs(root.path)
            }
        }

        for dir in [root, root.appendingPathComponent("env", isDirectory: true), byProjectDirectory(root: root)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // createDirectory 对**已存在**的目录不会去改属性，所以要再设一遍。
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }

        if !fm.fileExists(atPath: marker.path) {
            try Data("Vibe Foreman 的密钥物化目录。删掉这个文件，app 就不敢再清理这里。\n".utf8)
                .write(to: marker, options: .atomic)
        }
        // Spotlight 的 `.metadata_never_index` 在卷根目录上是明确生效的，
        // 目录级只是尽力而为。一行代码，做了不亏。
        let spotlight = root.appendingPathComponent(spotlightMarker)
        if !fm.fileExists(atPath: spotlight.path) {
            try? Data().write(to: spotlight, options: .atomic)
        }
    }

    enum Error: Swift.Error, LocalizedError {
        case notOurs(String)
        var errorDescription: String? {
            switch self {
            case .notOurs(let path):
                return "\(path) 已经存在而且不是 Vibe Foreman 建的（缺少 \(ownerMarker) 标记），拒绝接管"
            }
        }
    }

    /// 从 `url` 往上走到根，找有没有 `.git`。
    ///
    /// 不 shell out 到 `git rev-parse`：这个判断在每次写盘前都要跑，起进程太贵，
    /// 而且拉不进单元测试。
    ///
    /// **`.git` 是文件也算** —— git worktree 和 submodule 的 `.git` 就是个文本文件，
    /// 只认目录的话，在 worktree 里会判成「不在仓库内」然后照写不误。
    static func enclosingGitRepository(of url: URL) -> URL? {
        let fm = FileManager.default
        var current = url.resolvingSymlinksInPath().standardizedFileURL
        while true {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return nil }
            current = parent
        }
    }
}
