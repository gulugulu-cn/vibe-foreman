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
        // 仓库改过名，新旧两个目录名都找。Application Support 那份**不改名** ——
        // 那是用户数据落盘的地方，改了等于把已有的配置全孤立掉。
        urls.append(home.appendingPathComponent("Documents/code/vibe-foreman/projects.yaml"))
        urls.append(home.appendingPathComponent("Documents/code/claude-hub/projects.yaml"))
        urls.append(
            home.appendingPathComponent("Library/Application Support/claude-hub/projects.yaml")
        )
        return urls
    }

    /// 新条目往哪儿写。
    ///
    /// 没有任何已知文件时回落到 **Application Support**（候选表的最后一项，
    /// app 自己的数据目录），而不是 `candidateURLs.first` —— 那是
    /// 「仓库大概克隆在 ~/Documents/code 下」的假设，仓库放在别处时
    /// 那个目录根本不存在，写入会静默落空（issue #1）。
    public var writeTargetURL: URL? { sourceURL ?? candidateURLs.last }

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
            refreshMissing()
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

    // MARK: - 失效项目

    /// 目录已经不在了的项目（key 是 `Project.id`）。
    ///
    /// ## 为什么必须显式标出来
    ///
    /// tmux 对不存在的 `-c` 目录**返回 0 并静默回落到家目录**，`open` 则
    /// 什么都不做。所以一条指向已删除目录的记录，表现出来是
    /// 「Finder 没反应」+「Claude 开到家目录」——看起来像界面坏了。
    /// 实机上 40 条里有 6 条是这样的，而列表上一点痕迹都没有。
    public private(set) var missingPaths: Set<String> = []

    public func isMissing(_ project: Project) -> Bool { missingPaths.contains(project.id) }

    /// 重新检查每个项目的目录还在不在。
    ///
    /// 跟着 git 轮询走：40 次 stat 是微秒级的，而"目录被删了"这件事
    /// 本来就该在下一次刷新时就看见，不该等重启。
    private func refreshMissing() {
        var missing: Set<String> = []
        for project in projects {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: project.expandedPath, isDirectory: &isDirectory
            )
            if !exists || !isDirectory.boolValue { missing.insert(project.id) }
        }
        if missing != missingPaths { missingPaths = missing }
    }

    // MARK: - 增删

    /// 把项目从 yaml 里删掉。
    ///
    /// **只动列表，不碰磁盘上的目录。** 用户要清理的是这份清单里的脏数据，
    /// 不是他的代码 —— 一个"移除"按钮顺手删了工作区是不可接受的。
    @discardableResult
    public func remove(_ projects: [Project]) -> Bool {
        guard !projects.isEmpty, let url = sourceURL,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return false }

        let names = Set(projects.map(\.name))
        let updated = ProjectYAML.removing(names: names, from: text)
        guard updated != text else { return false }
        guard (try? updated.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return false }

        load()
        return true
    }

    /// 一键清掉全部失效项目。
    public var missingProjects: [Project] { projects.filter { missingPaths.contains($0.id) } }

    /// 手工把一个已有目录登记成项目。
    ///
    /// **扫描只认有 `.git` 的目录**，所以 monorepo 里的子目录、还没 git init
    /// 的目录永远扫不进来 —— 实机上 40 条里有 7 条属于这种，只能手写 yaml。
    /// 这是"能加载进去"这件事真正缺的那个入口。
    @discardableResult
    public func addExisting(path rawPath: String, name rawName: String? = nil) -> Bool {
        let path = normalize(rawPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }

        // 已经登记过就别加第二遍 —— 重名条目会让"删除"变得没法预测。
        guard !projects.contains(where: { normalize($0.expandedPath) == path }) else {
            return false
        }
        guard let url = writeTargetURL else { return false }

        let trimmed = rawName?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = trimmed.isEmpty ? (path as NSString).lastPathComponent : trimmed
        // 如实上报 —— 这里曾经无条件返回 true，append 一个字都没写
        // 也照样谎报成功，UI 层拿不到任何失败信号（issue #1）。
        guard Self.append(entries: [(name, path)], to: url) else { return false }
        load()
        return true
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

    /// 上一轮 git 采集还在跑吗。见 `refreshGit` 里的说明。
    @ObservationIgnored private var refreshingGit = false

    public func refreshGit() {
        let paths = projects.map(\.expandedPath)
        guard !paths.isEmpty else { return }

        // **上一轮没跑完就跳过这一轮。**
        //
        // 定时器是每 6 秒无条件触发的，而这里是串行遍历所有项目。
        // 注释里"21 个仓库约 120ms"的前提早就不成立了 —— 实测已经 40 个仓库，
        // 一轮跑不完下一轮就叠上来，`Task.detached` 无限累积。
        // 每个 `Shell.run` 要占 4 个 fd，而 GUI app 从 launchd 继承的
        // fd 软上限只有 256：实测这个进程的 fd 占用能冲到 251。
        // 撞顶之后所有探测同时开始"没有答案"，那才是真正伤人的地方
        //（见 `Shell.Result` 和 `TmuxProbe.attachedSessionNames` 的注释）。
        guard !refreshingGit else { return }
        refreshingGit = true

        // 40 个仓库串行。放后台队列，别让 UI 掉帧。
        Task.detached(priority: .utility) {
            var collected: [String: GitInfo] = [:]
            for path in paths {
                if let info = GitStatus.collect(at: path) {
                    collected[path] = info
                }
            }
            await MainActor.run { [collected] in
                self.gitInfo = collected
                self.refreshingGit = false
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
        guard let target = writeTargetURL else { return }
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
    @discardableResult
    nonisolated static func append(paths: [String], to url: URL) -> Bool {
        append(entries: paths.map { (($0 as NSString).lastPathComponent, $0) }, to: url)
    }

    /// 返回是否**真的落盘了**。
    ///
    /// 早先这里读不到文件就直接 return：全新安装时一份 yaml 都还没有，
    /// 于是「添加目录」「扫描」全部静默失败，看起来像按钮是坏的（issue #1）。
    /// 现在文件不存在就建父目录 + 写出骨架；写没写成，调用方必须能知道。
    @discardableResult
    nonisolated static func append(entries: [(name: String, path: String)], to url: URL) -> Bool {
        guard !entries.isEmpty else { return false }

        var text: String
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            text = existing
        } else {
            text = "projects:\n"
            guard (try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )) != nil else { return false }
        }

        text = normalizeProjectsKey(in: text)
        text = ensureProjectsKey(in: text)
        if !text.hasSuffix("\n") { text += "\n" }
        for entry in entries {
            text += "  - name: \(entry.name)\n    path: \(entry.path)\n"
        }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// 文件里连顶格 `projects:` 键都没有时补一个到末尾 ——
    /// 不补的话追加的条目是没有父键的孤儿，解析器整段忽略。
    nonisolated static func ensureProjectsKey(in text: String) -> String {
        let hasKey = text.components(separatedBy: "\n").contains { line in
            !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && line.trimmingCharacters(in: .whitespaces).hasPrefix("projects:")
        }
        guard !hasKey else { return text }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result + "projects:\n"
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
