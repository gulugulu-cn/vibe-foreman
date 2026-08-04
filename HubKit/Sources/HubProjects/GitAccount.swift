import Foundation
import HubProbe

/// 一个已登录的 git 托管账号（来自 gh CLI 的凭据）。
public struct GitAccount: Equatable, Sendable, Identifiable, Codable {
    public let host: String
    public let login: String
    public let active: Bool

    public var id: String { "\(host)/\(login)" }

    public init(host: String, login: String, active: Bool) {
        self.host = host
        self.login = login
        self.active = active
    }
}

/// 解析 `gh auth status` 的输出。
///
/// gh 没有给这条命令提供 --json，只能解析人读文本。格式（gh 2.x）：
/// ```
/// github.com
///   ✓ Logged in to github.com account anjiacm (keyring)
///   - Active account: true
/// ```
public enum GitAccountParser {
    public static func parse(_ text: String) -> [GitAccount] {
        var accounts: [GitAccount] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "Logged in to ") {
                // "Logged in to <host> account <login> (keyring)"
                let rest = trimmed[range.upperBound...]
                let parts = rest.components(separatedBy: " ")
                if parts.count >= 3, parts[1] == "account" {
                    accounts.append(GitAccount(host: parts[0], login: parts[2], active: false))
                }
            } else if trimmed.hasPrefix("- Active account: true"), let last = accounts.popLast() {
                accounts.append(GitAccount(host: last.host, login: last.login, active: true))
            }
        }
        return accounts
    }

    /// 解析 `gh api --paginate --jq` 输出的 NDJSON（一行一个仓库对象）。
    /// 用 --jq 出行式输出是刻意的：--paginate 直接拼 JSON 会产出多个并排的
    /// 数组，标准 JSONDecoder 解不了；行式则天然可拼接。
    public static func parseRepoLines(_ text: String) -> [RemoteRepo] {
        text.components(separatedBy: "\n").compactMap { line in
            guard let data = line.data(using: .utf8), !line.isEmpty else { return nil }
            return try? JSONDecoder().decode(RemoteRepo.self, from: data)
        }
    }
}

/// 账号可及的一个远程仓库（含个人仓、协作仓、组织仓）。
public struct RemoteRepo: Equatable, Sendable, Identifiable, Codable {
    public let nameWithOwner: String
    public let isPrivate: Bool

    public var id: String { nameWithOwner }

    public init(nameWithOwner: String, isPrivate: Bool) {
        self.nameWithOwner = nameWithOwner
        self.isPrivate = isPrivate
    }
}

/// gh 账号状态 + 仓库列表。设置页和克隆表单共用**同一个实例**（主窗口持有），
/// 外加磁盘缓存 —— 打开表单先显示上次的列表，后台静默刷新，不让用户等。
@Observable
@MainActor
public final class GitAccountStore {

    public private(set) var accounts: [GitAccount] = []
    /// 仓库按账号分开存：切回上一个账号时立刻有列表，不用重拉。
    public private(set) var reposByAccount: [String: [RemoteRepo]] = [:]
    /// gh 不可用 / 未登录时的说明文字。nil = 一切正常。
    public private(set) var diagnostic: String?
    public private(set) var isRefreshing = false
    /// 正在切换账号（gh auth switch 跑着）。
    public private(set) var isSwitching = false
    /// 上次成功刷新的时间（含从缓存读出的那份）。
    public private(set) var lastRefreshed: Date?

    /// 当前生效的账号。gh 的 clone/api 都用它，所以克隆私有仓看的是这个。
    public var activeAccount: GitAccount? {
        accounts.first(where: \.active) ?? accounts.first
    }

    /// 当前账号可见的仓库。
    public var repos: [RemoteRepo] {
        guard let id = activeAccount?.id else { return [] }
        return reposByAccount[id] ?? []
    }

    /// 仓库列表里出现过的 owner（个人 + 组织），按仓库数从多到少。
    /// 给 UI 做筛选标签用 —— 一个账号能看到十几个组织时，搜索框不够用。
    public var owners: [(name: String, count: Int)] {
        var tally: [String: Int] = [:]
        for repo in repos {
            let owner = repo.nameWithOwner.components(separatedBy: "/").first ?? ""
            guard !owner.isEmpty else { continue }
            tally[owner, default: 0] += 1
        }
        return tally
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    public static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/git-account-cache.json")
    }

    /// nil = 不落盘。可注入，理由同 ApprovalCoordinator.logURL：测试不许碰真实缓存。
    private let cacheURL: URL?

    private struct Cache: Codable {
        var accounts: [GitAccount]
        var reposByAccount: [String: [RemoteRepo]]
        var fetchedAt: Date
    }

    public init(cacheURL: URL? = GitAccountStore.defaultCacheURL) {
        self.cacheURL = cacheURL
        if let cacheURL,
           let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            accounts = cache.accounts
            reposByAccount = cache.reposByAccount
            lastRefreshed = cache.fetchedAt
        }
    }

    /// 切到另一个已登录账号。
    ///
    /// 这会改 gh 的全局活跃账号（等价于终端里 `gh auth switch`）——
    /// 之后的 clone / api 都走新账号。这正是跨账号拉私有仓需要的：
    /// gh 只用活跃账号的凭据，不切就看不见另一个账号的私有仓。
    /// 可逆（切回来即可），所以不做二次确认，但 UI 上要标清当前是谁。
    public func switchTo(_ account: GitAccount) {
        guard !isSwitching, !isRefreshing, !account.active else { return }
        isSwitching = true

        Task.detached(priority: .userInitiated) {
            let result = Shell.run(
                "/usr/bin/env",
                ["gh", "auth", "switch", "--hostname", account.host, "--user", account.login],
                timeout: 30,
                environment: ["PATH": NewProjectCommand.guiPATH]
            )
            await MainActor.run {
                self.isSwitching = false
                if result.succeeded {
                    // 乐观更新：refresh 回来之前列表就切过去，点击立刻有反馈。
                    self.accounts = self.accounts.map {
                        GitAccount(host: $0.host, login: $0.login, active: $0.id == account.id)
                    }
                    self.diagnostic = nil
                } else {
                    self.diagnostic = "切换账号失败：\(result.stderr.prefix(120))"
                }
                self.refresh()
            }
        }
    }

    /// 后台刷新。已有数据（缓存或上一轮）保持可见，刷完原地替换。
    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task.detached(priority: .utility) {
            let env = ["PATH": NewProjectCommand.guiPATH]
            let status = Shell.run(
                "/usr/bin/env", ["gh", "auth", "status"], timeout: 15, environment: env
            )
            let statusText = status.stdout + "\n" + status.stderr
            let parsed = GitAccountParser.parse(statusText)

            var repos: [RemoteRepo] = []
            var diagnostic: String?
            if parsed.isEmpty {
                diagnostic = statusText.contains("Logged in") == false && status.stdout.isEmpty
                    ? "找不到 gh 或未登录。终端跑：gh auth login"
                    : "gh 未登录。在终端跑：gh auth login"
            } else {
                // /user/repos + affiliation：个人仓、协作仓、**组织仓**全都要 ——
                // `gh repo list` 只列个人名下的仓，组织的看不见（真实反馈）。
                // sort=pushed：最近动过的排前面，克隆场景基本都是找它们。
                let list = Shell.run(
                    "/usr/bin/env",
                    [
                        "gh", "api",
                        "user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member",
                        "--paginate",
                        "--jq", ".[] | {nameWithOwner: .full_name, isPrivate: .private}",
                    ],
                    timeout: 60, environment: env
                )
                repos = GitAccountParser.parseRepoLines(list.stdout)
                if repos.isEmpty, !list.succeeded {
                    diagnostic = "仓库列表拉取失败：\(list.stderr.prefix(120))"
                }
            }

            await MainActor.run { [parsed, repos, diagnostic] in
                self.accounts = parsed
                // 只覆盖**当前活跃账号**那一格，别把其他账号的缓存冲掉。
                // 拉挂了也别清空 —— 网络抖一下不该让列表变白。
                if let id = self.activeAccount?.id, !repos.isEmpty || diagnostic == nil {
                    self.reposByAccount[id] = repos
                }
                self.diagnostic = diagnostic
                self.isRefreshing = false
                if diagnostic == nil {
                    self.lastRefreshed = Date()
                    self.persistCache()
                }
            }
        }
    }

    /// 测试用：直接灌一组账号和「当前账号的」仓库，不碰 gh。
    public func debugSeed(accounts: [GitAccount], repos: [RemoteRepo]) {
        self.accounts = accounts
        if let id = activeAccount?.id { reposByAccount[id] = repos }
    }

    private func persistCache() {
        guard let cacheURL else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let cache = Cache(
            accounts: accounts, reposByAccount: reposByAccount,
            fetchedAt: lastRefreshed ?? Date()
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// 「克隆项目」表单的命令模型。真正干活的是 scripts/clone-project.sh。
public struct CloneCommand: Equatable, Sendable {
    /// owner/repo、https 地址或 git@ 地址。
    public var repo: String = ""
    public var parentDir: String = "~/Documents/code"
    /// 本地目录名覆盖。空 = 用仓库名。
    public var nameOverride: String = ""

    public init() {}

    public var trimmedRepo: String {
        repo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 repo 各种写法里推出本地目录名。
    public var derivedName: String {
        if !nameOverride.trimmingCharacters(in: .whitespaces).isEmpty {
            return nameOverride.trimmingCharacters(in: .whitespaces)
        }
        var tail = trimmedRepo
        if let colon = tail.range(of: ":"), tail.hasPrefix("git@") {
            tail = String(tail[colon.upperBound...])
        }
        tail = tail.components(separatedBy: "/").last ?? tail
        if tail.hasSuffix(".git") { tail = String(tail.dropLast(4)) }
        return tail
    }

    public var validationError: String? {
        if trimmedRepo.isEmpty { return "仓库不能为空" }
        if derivedName.isEmpty { return "推不出目录名，请手动填" }
        if parentDir.trimmingCharacters(in: .whitespaces).isEmpty { return "父目录不能为空" }
        return nil
    }

    public func arguments(scriptPath: String) -> [String] {
        var args = [scriptPath, trimmedRepo, "--dir", parentDir]
        let name = nameOverride.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { args += ["--name", name] }
        return args
    }

    public static func scriptURL(near yamlURL: URL?) -> URL {
        NewProjectCommand.scriptURL(near: yamlURL)
            .deletingLastPathComponent()
            .appendingPathComponent("clone-project.sh")
    }
}
