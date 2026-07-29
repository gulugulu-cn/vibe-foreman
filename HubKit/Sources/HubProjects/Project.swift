import Foundation

/// projects.yaml 里的一个项目。
public struct Project: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let aliases: [String]
    public let description: String?
    public let tags: [String]

    public var id: String { path }

    public init(
        name: String, path: String, aliases: [String] = [],
        description: String? = nil, tags: [String] = []
    ) {
        self.name = name
        self.path = path
        self.aliases = aliases
        self.description = description
        self.tags = tags
    }

    /// 展开 `~/`。yaml 里普遍写成 `~/Documents/code/xxx`。
    public var expandedPath: String {
        guard path.hasPrefix("~") else { return path }
        return NSString(string: path).expandingTildeInPath
    }
}

/// git 状态。
/// 一条提交记录。
public struct GitCommit: Hashable, Sendable, Identifiable {
    public let hash: String
    public let subject: String
    /// git 自己给的相对时间（"3 minutes ago"）—— 不自己算，省一次时间戳解析，
    /// 而且 git 的措辞已经本地化过。
    public let relativeDate: String
    public let author: String

    public var id: String { hash }

    public init(hash: String, subject: String, relativeDate: String, author: String) {
        self.hash = hash
        self.subject = subject
        self.relativeDate = relativeDate
        self.author = author
    }
}

/// 一个仓库工作区的快照：状态 + 最近提交。
///
/// 按**会话的 cwd** 采集而不是按 projects.yaml 里的项目 —— 会话可能开在
/// 任意目录、任意 worktree，甚至根本不在已登记的项目里。同一个项目多开时，
/// 这份快照是区分它们的主要依据。
public struct WorkspaceGit: Hashable, Sendable {
    public let root: String
    public let info: GitInfo
    public let recent: [GitCommit]

    public init(root: String, info: GitInfo, recent: [GitCommit]) {
        self.root = root
        self.info = info
        self.recent = recent
    }
}

public struct GitInfo: Hashable, Sendable {
    public let branch: String?
    public let changeCount: Int
    public let ahead: Int
    public let behind: Int
    public let hasUpstream: Bool

    public var isClean: Bool { changeCount == 0 }

    public init(
        branch: String?, changeCount: Int, ahead: Int, behind: Int, hasUpstream: Bool
    ) {
        self.branch = branch
        self.changeCount = changeCount
        self.ahead = ahead
        self.behind = behind
        self.hasUpstream = hasUpstream
    }
}

/// 极简 YAML 解析。
///
/// 只认 projects.yaml 这一种结构，不引 Yams。理由是常驻 app 的长期维护成本：
/// 多一个依赖就多一次跟着 Swift 版本升级的负担，而这里需要的表达力极其有限。
///
/// 沿用现有 Rust 版 `parse_yaml` 的宽松行解析契约（trim 后判前缀），
/// 这样两边对同一个文件的理解一致，迁移期间不会打架。
public enum ProjectYAML {

    /// 解析结果 + 诊断。
    ///
    /// 存在的理由是一次真实事故：文件里明明有 117 条项目，解析器却返回空数组，
    /// UI 老老实实显示"0 个项目"，**没有任何地方提示出了问题**。
    /// 排查它花的时间远超写这个类型的成本 —— 解析失败必须能被看见。
    public struct Outcome: Sendable {
        public let projects: [Project]
        /// 文件里出现过多少个 `- name:`（不管有没有被成功解析）。
        public let entryMarkers: Int

        /// 文件里有条目但一条都没解析出来 —— 格式坏了。
        public var looksBroken: Bool { projects.isEmpty && entryMarkers > 0 }

        public var diagnostic: String? {
            guard looksBroken else { return nil }
            return "文件里有 \(entryMarkers) 条项目，但一条都没能解析出来 —— 检查 `projects:` 这一行的格式"
        }
    }

    public static func parse(_ text: String) -> [Project] {
        analyze(text).projects
    }

    public static func analyze(_ text: String) -> Outcome {
        var projects: [Project] = []
        var entryMarkers = 0

        var name: String?
        var path: String?
        var description: String?
        var aliases: [String] = []
        var tags: [String] = []
        var inProjectsSection = false

        func flush() {
            if let name, let path {
                projects.append(
                    Project(
                        name: name, path: path, aliases: aliases,
                        description: description, tags: tags
                    )
                )
            }
            name = nil
            path = nil
            description = nil
            aliases = []
            tags = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("- name:") || trimmed.hasPrefix("-name:") {
                entryMarkers += 1
            }

            // 顶层键。scan_dirs 之类的段落要跳过，只处理 projects。
            //
            // 判定必须按**键名**而不是整行字面量。踩过的坑：原来写的是
            // `trimmed == "projects:"`，于是 `projects: []` 完全不匹配 ——
            // 旧版留下的空数组标记后面被追加了 117 条项目，全部被静默忽略。
            // 行内值（`[]`、`~`、`null`）只是"暂时没有内联条目"，
            // 不代表下面缩进的列表不算数。
            if !line.hasPrefix(" ") && !line.hasPrefix("\t"),
               let key = topLevelKey(of: trimmed) {
                flush()
                inProjectsSection = key == "projects"
                continue
            }
            guard inProjectsSection else { continue }

            if trimmed.hasPrefix("- ") {
                flush()
                let rest = String(trimmed.dropFirst(2))
                if let value = value(of: "name", in: rest) { name = value }
                continue
            }

            if let value = value(of: "name", in: trimmed) { name = value }
            else if let value = value(of: "path", in: trimmed) { path = value }
            else if let value = value(of: "description", in: trimmed) { description = value }
            else if let value = value(of: "aliases", in: trimmed) { aliases = list(value) }
            else if let value = value(of: "tags", in: trimmed) { tags = list(value) }
        }
        flush()
        return Outcome(projects: projects, entryMarkers: entryMarkers)
    }

    /// 顶层键名。`projects:` / `projects: []` / `scan_dirs:` 都能取到键名；
    /// 列表项（`- xxx`）和纯文本行返回 nil。
    private static func topLevelKey(of trimmed: String) -> String? {
        guard !trimmed.hasPrefix("-"), let colon = trimmed.firstIndex(of: ":") else {
            return nil
        }
        let key = String(trimmed[trimmed.startIndex..<colon])
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        return key
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = key + ":"
        guard line.hasPrefix(prefix) else { return nil }
        return unquote(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
    }

    private static func list(_ raw: String) -> [String] {
        var body = raw
        if body.hasPrefix("["), body.hasSuffix("]") {
            body = String(body.dropFirst().dropLast())
        }
        return body
            .split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ raw: String) -> String {
        var value = raw
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
