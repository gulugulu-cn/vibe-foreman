import Foundation
import HubProbe

/// 项目列表 + git 状态。
@Observable
@MainActor
public final class ProjectStore {

    public private(set) var projects: [Project] = []
    public private(set) var gitInfo: [String: GitInfo] = [:]   // key = expandedPath
    public private(set) var isScanning = false

    /// 置顶的项目。key = `Project.id`（yaml 里的 path 原文，含 `~`），
    /// 这样 yaml 重载、项目暂时消失再回来，置顶都不丢。
    public private(set) var pinned: Set<String> = []

    /// 实际读到的那个文件。
    ///
    /// **必须对外可见。** 这次的坑就是"不知道 app 在读哪份 projects.yaml" ——
    /// 脚本和 CLAUDE.md 维护的是仓库里那份，app 却在读 Application Support 里
    /// 另一份旧的，两边永远对不上，而 UI 上只显示一个孤零零的"0 个项目"。
    public private(set) var sourceURL: URL?

    /// 解析失败的说明。UI 要显示出来，不能让文件坏了还静默显示 0。
    public private(set) var loadDiagnostic: String?

    private let explicitURL: URL?
    private var gitTimer: Timer?

    /// cwd → 项目名 的反查表。hook 事件只带 cwd，要靠它换成用户认识的项目名。
    private var pathIndex: [String: String] = [:]

    /// 置顶状态的落盘位置。和 approval-log.json 一样放 Application Support。
    public static var defaultPinURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/pinned.json")
    }

    /// nil = 不落盘。必须可注入，理由同 ApprovalCoordinator.logURL：
    /// 路径写死会让测试直接污染用户的真实数据。
    private let pinURL: URL?

    public init(yamlURL: URL? = nil, pinURL: URL? = ProjectStore.defaultPinURL) {
        self.explicitURL = yamlURL
        self.pinURL = pinURL
        loadPins()
    }

    // MARK: - 置顶

    public func isPinned(_ project: Project) -> Bool {
        pinned.contains(project.id)
    }

    public func togglePin(_ project: Project) {
        if pinned.contains(project.id) {
            pinned.remove(project.id)
        } else {
            pinned.insert(project.id)
        }
        persistPins()
    }

    private func loadPins() {
        guard let pinURL,
              let data = try? Data(contentsOf: pinURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        pinned = Set(decoded)
    }

    /// 不清理已消失项目的 pin：项目可能只是暂时从 yaml 移走，脏数据无害且量极小。
    private func persistPins() {
        guard let pinURL else { return }
        try? FileManager.default.createDirectory(
            at: pinURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // sorted 保证写盘内容稳定，diff 友好。
        guard let data = try? JSONEncoder().encode(pinned.sorted()) else { return }
        try? data.write(to: pinURL, options: .atomic)
    }

    // MARK: - 加载

    /// 按优先级找 projects.yaml。
    ///
    /// **仓库那份优先**：`add-project.sh`、`scan-projects.sh` 和 CLAUDE.md
    /// 全都以它为准，app 读别处就等于两套数据。Application Support 那份
    /// 只作为"没有克隆仓库"时的兜底。
    public var candidateURLs: [URL] {
        if let explicitURL { return [explicitURL] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_HUB_DIR"], !dir.isEmpty {
            urls.append(
                URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath)
                    .appendingPathComponent("projects.yaml")
            )
        }
        urls.append(home.appendingPathComponent("Documents/code/claude-hub/projects.yaml"))
        urls.append(
            home.appendingPathComponent("Library/Application Support/claude-hub/projects.yaml")
        )
        return urls
    }

    public func load() {
        loadDiagnostic = nil

        // 逐个候选试。**空文件和解析不出东西的文件都要继续往下找** ——
        // 只判断"文件存不存在"的话，一份坏掉的文件会把好的那份永远挡住，
        // 这正是这次 0 个项目的成因。
        var firstFound: (URL, ProjectYAML.Outcome)?
        for url in candidateURLs {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let outcome = ProjectYAML.analyze(text)
            if firstFound == nil { firstFound = (url, outcome) }
            guard !outcome.projects.isEmpty else { continue }

            sourceURL = url
            projects = outcome.projects
            rebuildPathIndex()
            refreshGit()
            return
        }

        // 一个候选都没解析出项目：如实报告最先找到的那份出了什么问题。
        if let (url, outcome) = firstFound {
            sourceURL = url
            projects = []
            loadDiagnostic = outcome.diagnostic ?? "文件里没有任何项目条目"
        } else {
            sourceURL = nil
            projects = []
            loadDiagnostic = "找不到 projects.yaml"
        }
        rebuildPathIndex()
    }

    private func rebuildPathIndex() {
        pathIndex = [:]
        for project in projects {
            pathIndex[normalize(project.expandedPath)] = project.name
        }
    }

    /// 从任意路径反查项目名。
    ///
    /// 会话的 cwd 常常是项目的**子目录**（用户 cd 进去再起的 claude），
    /// 所以要逐级向上找最长匹配，不能只做等值比较。
    public func projectName(forPath path: String) -> String? {
        var current = normalize(path)
        while !current.isEmpty, current != "/" {
            if let name = pathIndex[current] { return name }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func normalize(_ path: String) -> String {
        var value = NSString(string: path).expandingTildeInPath
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    // MARK: - git

    public func startGitPolling() {
        refreshGit()
        gitTimer?.invalidate()
        // git 状态变化远没有会话状态那么频繁，6 秒足够。
        gitTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshGit() }
        }
    }

    public func stopGitPolling() {
        gitTimer?.invalidate()
        gitTimer = nil
    }

    public func refreshGit() {
        let paths = projects.map(\.expandedPath)
        guard !paths.isEmpty else { return }

        // 21 个仓库串行大约 120ms。放后台队列，别让 UI 掉帧。
        Task.detached(priority: .utility) {
            var collected: [String: GitInfo] = [:]
            for path in paths {
                if let info = GitStatus.collect(at: path) {
                    collected[path] = info
                }
            }
            await MainActor.run { [collected] in
                self.gitInfo = collected
            }
        }
    }

    public func git(for project: Project) -> GitInfo? {
        gitInfo[project.expandedPath]
    }

    /// 按任意路径找 git 状态。
    ///
    /// 会话的 cwd 常常是项目的子目录，所以和 `projectName(forPath:)` 一样
    /// 逐级向上找最长匹配 —— 直接拿 cwd 当 key 去查会大面积落空。
    public func git(forPath path: String) -> GitInfo? {
        var current = normalize(path)
        while !current.isEmpty, current != "/" {
            if let info = gitInfo[current] { return info }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: - 扫描

    /// 扫描目录树，把新发现的 git 仓库追加进 yaml。
    public func scan(root: String = "~/Documents/code") {
        guard !isScanning else { return }
        let target = sourceURL ?? candidateURLs.first
        guard let target else { return }
        isScanning = true

        let existing = Set(projects.map { self.normalize($0.expandedPath) })

        Task.detached(priority: .userInitiated) {
            let found = GitStatus.scanRepositories(under: root)
            let fresh = found.filter { !existing.contains($0) }

            if !fresh.isEmpty {
                Self.append(paths: fresh, to: target)
            }

            await MainActor.run {
                self.isScanning = false
                self.load()
            }
        }
    }

    /// 把新发现的项目追加进 yaml。
    ///
    /// 追加而不是重写整份：用户手写的别名、描述、注释都要保住。
    ///
    /// 但**追加前必须先规范化 `projects:` 那一行**。这次的事故就是这么来的：
    /// 文件里是 `projects: []`（旧版写的空数组），追加逻辑直接 seek 到文件尾
    /// 写条目，产出的 YAML 变成"空数组标记后面跟着 117 条内容" ——
    /// 解析器看到 `[]` 就认定项目段是空的，全部忽略。
    nonisolated static func append(paths: [String], to url: URL) {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }

        text = normalizeProjectsKey(in: text)
        if !text.hasSuffix("\n") { text += "\n" }
        for path in paths {
            let name = (path as NSString).lastPathComponent
            text += "  - name: \(name)\n    path: \(path)\n"
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 把 `projects: []` / `projects: ~` / `projects: null` 还原成 `projects:`，
    /// 让后面缩进的列表条目重新生效。其余内容一字不动。
    nonisolated static func normalizeProjectsKey(in text: String) -> String {
        let emptyMarkers: Set<String> = ["[]", "~", "null", "{}"]
        var lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("projects:") else { continue }
            let value = String(trimmed.dropFirst("projects:".count))
                .trimmingCharacters(in: .whitespaces)
            if emptyMarkers.contains(value) {
                lines[index] = "projects:"
            }
            break
        }
        return lines.joined(separator: "\n")
    }
}
