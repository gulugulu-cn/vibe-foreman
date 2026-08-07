import Foundation
import HubCore
import HubProjects
import Observation

/// 验收清单的仓库。一个项目一份清单，跨会话累积。
///
/// ## 为什么按项目而不是按会话
///
/// 用户关了终端第二天再开是常态。清单挂在会话上的话，每天早上都从零开始，
/// 「跨轮次追踪漏掉的」这个需求直接落空。会话只是"哪一轮动过它"，
/// 记在 `AcceptanceItem.sourceSessionId` 里。
///
/// ## 落盘：一项目一文件
///
/// 不用一个大 JSON。理由是导出归档和排障都按项目走，一项目一文件时
/// 「把某个项目的清单发给别人」「手动改坏了只影响一个项目」都是直接的。
@Observable
@MainActor
public final class AcceptanceStore {

    /// 全部清单，key = 项目绝对路径。
    public private(set) var ledgers: [String: AcceptanceLedger] = [:]

    /// 落盘目录。nil = 不落盘。
    ///
    /// **必须可注入。** 理由同 `ApprovalCoordinator.logURL`：路径写死在类型里，
    /// 测试就会直接读写用户的真实清单 —— 测试之间互相污染是小事，
    /// 往用户数据里写测试垃圾是真问题。
    @ObservationIgnored
    private let directory: URL?

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/acceptance")
    }

    public init(directory: URL? = AcceptanceStore.defaultDirectory) {
        self.directory = directory
        loadAll()
    }

    // MARK: - 拦截的「上膛」
    //
    // 这一段是全案防死循环的核心，展开说清楚为什么长这样。
    //
    // Stop hook 改成阻塞式之后，Hub 可以在 Claude 收工时把清单塞回去逼它逐条核对。
    // 但塞回去之后 Claude 会再回复一轮，于是又触发 Stop —— 如果那时还满足拦截条件，
    // 就又塞一次。这是个真能把会话卡死的无限循环。
    //
    // 常见做法是加计数器或时间窗去挡。**这里不那么做**，因为"挡"意味着总有
    // 某个边界情况能绕过去，而代价是用户的会话卡住。
    //
    // 改成结构上不可能：**只有 `UserPromptSubmit` 能上膛**，而那个 hook 只在
    // 用户敲回车时触发。Stop 一旦拦过就立刻卸膛。Claude 没有任何路径能给自己
    // 上膛 —— 循环不是被挡住，是构造不出来。
    //
    // 这些状态刻意**不落盘**：app 重启后一律视为未上膛，最坏情况是少拦一次，
    // 而落盘可能让重启后凭空拦一次，方向错了。

    @ObservationIgnored
    private var armedSessions: Set<String> = []

    /// 用户说话了 —— 给这个会话上膛。**唯一的上膛入口。**
    public func arm(sessionId: String) {
        armedSessions.insert(sessionId)
    }

    /// Stop 到了：卸膛并回答"这次该不该拦"。
    ///
    /// **卸膛在最前面，早于任何其它判断。** 无论后面 return 什么、中途出什么错，
    /// 膛都已经空了 —— 这是循环构造不出来的原因。
    public func disarmAndShouldIntercept(sessionId: String, projectPath: String) -> Bool {
        let wasArmed = armedSessions.remove(sessionId) != nil
        guard wasArmed else { return false }
        // 清单里没有待办就别打扰 —— 没启用这功能的项目必须完全无感。
        return ledger(for: projectPath).items.contains(where: \.needsAttention)
    }

    /// 只读地看一眼有没有上膛。给测试和排障用，不改状态。
    public func isArmed(sessionId: String) -> Bool { armedSessions.contains(sessionId) }

    // MARK: - 第一手改动记录
    //
    // PostToolUse 报上来的被改文件。**这是 Hub 亲眼看到的，不是 Claude 转述的。**
    // 「实际功能证明」最便宜的一半就在这儿：不用问"你改了什么"，
    // 而问这个问题本身就给了转述失真的机会。
    //
    // 只存内存：它是"这一轮干了什么"的快照，app 重启后本来也无从谈起。

    @ObservationIgnored
    private var touched: [String: [String]] = [:]

    public func recordTouchedFile(_ path: String, sessionId: String) {
        var files = touched[sessionId] ?? []
        guard !files.contains(path) else { return }
        // 一轮里改几百个文件是可能的（大规模重构），留个上界防止无限长。
        if files.count >= 300 { files.removeFirst() }
        files.append(path)
        touched[sessionId] = files
    }

    public func touchedFiles(sessionId: String) -> [String] { touched[sessionId] ?? [] }

    /// 一轮验收结束后清掉，下一轮重新攒。
    public func clearTouchedFiles(sessionId: String) { touched[sessionId] = nil }

    // MARK: - 验收命令的授权

    public func isAuthorized(_ command: String, in projectPath: String) -> Bool {
        ledger(for: projectPath).authorizedCommands.contains(command)
    }

    public func authorize(_ command: String, in projectPath: String) {
        mutate(projectPath) { ledger in
            guard !ledger.authorizedCommands.contains(command) else { return }
            ledger.authorizedCommands.append(command)
        }
    }

    public func revoke(_ command: String, in projectPath: String) {
        mutate(projectPath) { $0.authorizedCommands.removeAll { $0 == command } }
    }

    /// 记下一次真实执行的结果。
    ///
    /// 走 `.ran` 这一档，`isProof` 为 true —— 这是 Hub **亲手**跑出来的，
    /// 和 Claude 的自述不是一回事。
    public func recordVerification(_ evidence: Evidence, forID id: String, in projectPath: String) {
        mutate(projectPath) { ledger in
            guard let index = ledger.items.firstIndex(where: { $0.id == id }) else { return }
            ledger.items[index].evidence.append(evidence)
            ledger.items[index].updatedAt = Date()
        }
    }

    // MARK: - 读

    /// 取某个项目的清单。没有就返回一份空的（不落盘，等到真有内容再写）。
    public func ledger(for projectPath: String) -> AcceptanceLedger {
        ledgers[projectPath] ?? AcceptanceLedger(projectPath: projectPath)
    }

    /// 有内容的项目路径，需要关注的排前面。
    public var projectPaths: [String] {
        ledgers.values
            .filter { !$0.isEmpty }
            .sorted {
                let left = $0.disputedCount * 100 + $0.openCount
                let right = $1.disputedCount * 100 + $1.openCount
                if left != right { return left > right }
                return $0.projectPath < $1.projectPath
            }
            .map(\.projectPath)
    }

    /// 把会话的 cwd 归到项目路径。
    ///
    /// cwd 常常是项目的子目录（用户 cd 进去再起的 claude），所以要走
    /// `ProjectStore.projectName(forPath:)` 的逐级向上匹配。归不到已注册项目时
    /// 退回 cwd 本身 —— 没登记的目录也该有清单，不然这功能只对登记过的项目生效。
    public static func projectPath(forCWD cwd: String, projects: ProjectStore) -> String {
        guard let name = projects.projectName(forPath: cwd),
              let project = projects.projects.first(where: { $0.name == name })
        else { return NSString(string: cwd).expandingTildeInPath }
        return project.expandedPath
    }

    // MARK: - 写

    public func add(_ item: AcceptanceItem, to projectPath: String) {
        mutate(projectPath) { $0.items.append(item) }
    }

    public func update(_ item: AcceptanceItem, in projectPath: String) {
        mutate(projectPath) { ledger in
            guard let index = ledger.items.firstIndex(where: { $0.id == item.id }) else { return }
            var updated = item
            updated.updatedAt = Date()
            ledger.items[index] = updated
        }
    }

    public func remove(id: String, from projectPath: String) {
        mutate(projectPath) { $0.items.removeAll { $0.id == id } }
    }

    /// 用户手动改状态。这是终裁，`applyAudit` 不会再动它。
    public func setStatus(_ status: AcceptanceItem.Status, forID id: String, in projectPath: String) {
        mutate(projectPath) { ledger in
            guard let index = ledger.items.firstIndex(where: { $0.id == id }) else { return }
            ledger.items[index].status = status
            ledger.items[index].updatedAt = Date()
        }
    }

    /// 记一句用户原话。零成本，不调模型 —— 拆解是异步消费这个缓冲的。
    public func recordPrompt(_ prompt: RawPrompt, in projectPath: String) {
        mutate(projectPath) { $0.rawPrompts.append(prompt) }
    }

    /// 拆解消费完了，清掉已处理的原话。
    public func clearPrompts(upTo date: Date, in projectPath: String) {
        mutate(projectPath) { $0.rawPrompts.removeAll { $0.at <= date } }
    }

    /// 合并新拆出来的要点，按文本去重。
    ///
    /// 去重比对的是**所有**既有项（含已接受/已划掉）：用户划掉过的要点如果因为
    /// 又提了一次而重新入库，等于用户的决定被无视了。
    public func merge(_ incoming: [AcceptanceItem], into projectPath: String) {
        mutate(projectPath) { ledger in
            let existing = Set(ledger.items.map { Self.dedupKey($0.text) })
            for item in incoming where !existing.contains(Self.dedupKey(item.text)) {
                ledger.items.append(item)
            }
        }
    }

    /// 去重键：去掉空白和常见标点，忽略大小写。
    ///
    /// 只做到这个程度就够了 —— 真正的语义去重交给拆解那次模型调用
    /// （把既有清单一起喂给它，让它只输出新增的）。这里挡的是完全一样的重复。
    static func dedupKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - 自查回收与旁路复核

    /// 收下 Claude 的逐条自查回答。
    ///
    /// 只把 `.open` 推到 `.claimed`，**不推到 `.confirmed`** —— 它说做完了只是
    /// 一条待核验的线索，证据类型也如实记成 `.claimed`（`isProof == false`）。
    /// 真正的确认要等 `applyAudit` 拿 git diff 来核。
    public func applyClaims(_ claims: [AcceptanceClaim], in projectPath: String) {
        mutate(projectPath) { ledger in
            for claim in claims {
                guard let index = ledger.items.firstIndex(where: { $0.id == claim.id }) else {
                    continue
                }
                guard !ledger.items[index].isSettledByUser else { continue }
                guard claim.done else {
                    // 它自己承认没做 —— 保持 open，把理由记下来就够了。
                    ledger.items[index].note = claim.evidence
                    ledger.items[index].updatedAt = Date()
                    continue
                }
                ledger.items[index].status = .claimed
                ledger.items[index].evidence.append(.claimed(claim.evidence))
                ledger.items[index].updatedAt = Date()
            }
        }
    }

    /// 收下旁路复核（拿真实 git diff 判的）的结论。
    ///
    /// **必须跳过 `isSettledByUser` 的项。** 用户亲手勾了「接受」，机器再怎么判
    /// 都不许改回去 —— 这是对用户的承诺（"最终勾选权在你手上"），
    /// 有一条测试专门守这个。
    public func applyAudit(_ verdicts: [AcceptanceVerdict], in projectPath: String) {
        mutate(projectPath) { ledger in
            for verdict in verdicts {
                guard let index = ledger.items.firstIndex(where: { $0.id == verdict.id }) else {
                    continue
                }
                guard !ledger.items[index].isSettledByUser else { continue }
                ledger.items[index].status = verdict.confirmed ? .confirmed : .disputed
                ledger.items[index].evidence.append(contentsOf: verdict.evidence)
                if let note = verdict.note { ledger.items[index].note = note }
                ledger.items[index].updatedAt = Date()
            }
        }
    }

    // MARK: - 注入正文

    /// Stop 时塞回给 Claude 的清单正文。没有待办就返回 nil（= 不拦）。
    ///
    /// 措辞上有两处是刻意的：
    /// - 开头点明"来自用户原始需求和已批准的计划，不是你自己列的 todo"——
    ///   不这么说的话它会拿自己的 TodoWrite 来对照，那就白做了；
    /// - 结尾要求"输出完就停下"—— 否则它会顺手去补做遗漏项，
    ///   自查回答反而收不到（这个降级可以接受，但不该是默认行为）。
    public func injectionText(for projectPath: String) -> String? {
        let pending = ledger(for: projectPath).items.filter(\.needsAttention)
        guard !pending.isEmpty else { return nil }

        // 一次最多摆这么多条。
        //
        // 实测在一个真实项目上拦了 12 条，带完整验收条件之后糊了满屏 ——
        // 要点一多就没人看（Claude 也一样），反而比不拦更容易被忽略。
        // 存疑的排前面：那一档是「自报做完但代码里找不到」，最该先说清楚。
        let cap = 6
        let ordered = pending.sorted { left, right in
            (left.status == .disputed ? 0 : 1) < (right.status == .disputed ? 0 : 1)
        }
        let shown = Array(ordered.prefix(cap))

        var lines = shown.map { item -> String in
            let condition = item.acceptance.map { "（验收条件：\($0)）" } ?? ""
            return "- [\(item.id)] \(item.text)\(condition)"
        }
        if ordered.count > cap {
            // 省略了多少必须说出来。静默截断会让人以为"就这几条"。
            lines.append("（另有 \(ordered.count - cap) 条未列出，这轮先核对上面这些）")
        }

        return """
        【Claude Hub 验收守望】以下要点来自**用户的原始需求和已批准的计划**，\
        不是你自己列的 todo。逐条核对，给结论和证据。

        \(lines.joined(separator: "\n"))

        只输出一个 json 代码块，然后停下，不要继续做别的事：
        {"items":[{"id":"原样抄回方括号里的 id","done":true,\
        "evidence":"改了哪个文件的哪几行、跑了什么命令"}]}

        done 只在**代码里真有对应改动**时才填 true。没做就填 false 并说明原因，\
        不要编造证据 —— 这份回答会拿真实的 git diff 复核。
        """
    }

    // MARK: - 导出归档

    /// 导出 Markdown 报告。
    ///
    /// app 窗口窄，逐条证据和 diff 摊不开，所以完整内容走这份报告。
    /// 报告即归档，不做第二套渲染。
    public func markdownReport(for projectPath: String, projectName: String) -> String {
        let ledger = self.ledger(for: projectPath)
        let stamp = ISO8601DateFormatter().string(from: Date())

        var out = """
        # 验收报告 · \(projectName)

        > \(ledger.headline)
        > 生成于 \(stamp) · 项目路径 `\(projectPath)`

        """

        func section(_ title: String, _ items: [AcceptanceItem]) {
            guard !items.isEmpty else { return }
            out += "\n## \(title)（\(items.count)）\n\n"
            for item in items {
                out += "### \(item.text)\n\n"
                out += "- 来源：\(item.origin.label) · 状态：\(item.status.label)\n"
                if let acceptance = item.acceptance {
                    out += "- 验收条件：`\(acceptance)`\n"
                }
                if let note = item.note {
                    out += "- 备注：\(note)\n"
                }
                if item.evidence.isEmpty {
                    out += "- 证据：**无**\n"
                } else if !item.hasProof {
                    // 如实标注。只有自述而没有实测证明时，绝不能让报告读起来像已经验证过。
                    out += "- 证据：**仅自述，未经实测验证**\n"
                    for evidence in item.evidence {
                        out += "  - \(evidence.shortLabel)\n"
                    }
                } else {
                    out += "- 证据：\n"
                    for evidence in item.evidence {
                        let mark = evidence.isProof ? "✅" : "○"
                        out += "  - \(mark) \(evidence.shortLabel)\n"
                    }
                }
                for case .ran(let command, let exitCode, let tail) in item.evidence {
                    out += "\n<details><summary>`\(command)` → exit \(exitCode)</summary>\n\n"
                    out += "```\n\(tail)\n```\n\n</details>\n"
                }
                out += "\n"
            }
        }

        section("存疑（自报做完但代码里找不到）", ledger.items.filter { $0.status == .disputed })
        section("未验收", ledger.items.filter { $0.status == .open })
        section("待复核", ledger.items.filter { $0.status == .claimed })
        section("已确认", ledger.items.filter { $0.status == .confirmed })
        section("已接受", ledger.items.filter { $0.status == .accepted })
        section("已划掉", ledger.items.filter { $0.status == .dropped })

        return out
    }

    // MARK: - 持久化

    private func mutate(_ projectPath: String, _ body: (inout AcceptanceLedger) -> Void) {
        // 改之前先重读一次盘。
        //
        // 清单是给人看也给人改的 —— 手工编辑 JSON 补几条要点是完全合理的用法
        // （这条注释就是在我自己那么干之后加的：app 内存里的旧状态在下一次写入时
        // 把手改的内容整个盖掉了，无声无息）。每次写入后内存和磁盘是一致的，
        // 所以重读只可能捡回外部改动，不会丢掉自己的。
        reload(projectPath)

        var ledger = ledgers[projectPath] ?? AcceptanceLedger(projectPath: projectPath)
        body(&ledger)
        ledger.updatedAt = Date()
        ledgers[projectPath] = ledger
        persist(ledger)
    }

    private func fileURL(for projectPath: String) -> URL? {
        directory?.appendingPathComponent(
            UsageStats.encodeDirectoryName(for: projectPath) + ".json"
        )
    }

    /// 从盘上重读一份。文件不存在就什么都不做。
    ///
    /// **文件存在但解不出来时，先把它改名保住，再让调用方从空的开始。**
    ///
    /// 早先这里是 `try?` 一路吞到底：解码失败 → 内存里是空的 → 下一次写入
    /// 把用户攒了几周的清单整个覆盖掉，全程无声无息。真丢过一份 13 条的。
    ///
    /// 改名到 `.broken-<时间戳>` 之后，最坏情况也只是"这次读不出来"，
    /// 数据还在盘上能捞回来。**丢数据和读不出来是两个量级的事故。**
    private func reload(_ projectPath: String) {
        guard let url = fileURL(for: projectPath),
              let data = try? Data(contentsOf: url)
        else { return }

        if let ledger = try? JSONDecoder().decode(AcceptanceLedger.self, from: data) {
            ledgers[projectPath] = ledger
            return
        }

        let rescued = url.deletingPathExtension()
            .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: rescued)
        HubLog.app.error("""
        验收清单解不出来，已保留为 \(rescued.lastPathComponent, privacy: .public)
        """)
    }

    private func persist(_ ledger: AcceptanceLedger) {
        guard let directory, let url = fileURL(for: ledger.projectPath) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 启动时把所有清单读进来。
    ///
    /// 单个文件坏掉就跳过它，不让整个功能失效 —— 同 `TaskStateReader` 的处理：
    /// 清单是边跑边写的，撞上半截 JSON 是正常情况，不是异常。
    private func loadAll() {
        guard let directory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            guard let ledger = try? JSONDecoder().decode(AcceptanceLedger.self, from: data) else {
                // 同 reload：解不出来的先保住，别等下一次写入把它盖掉。
                let rescued = file.deletingPathExtension()
                    .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: file, to: rescued)
                HubLog.app.error("""
                启动时有清单解不出来，已保留为 \(rescued.lastPathComponent, privacy: .public)
                """)
                continue
            }
            ledgers[ledger.projectPath] = ledger
        }
    }
}

/// Claude 对某一条要点的自查回答。
public struct AcceptanceClaim: Sendable, Equatable {
    public let id: String
    public let done: Bool
    public let evidence: String

    public init(id: String, done: Bool, evidence: String) {
        self.id = id
        self.done = done
        self.evidence = evidence
    }
}

/// 旁路复核对某一条要点的结论。
public struct AcceptanceVerdict: Sendable, Equatable {
    public let id: String
    public let confirmed: Bool
    public let note: String?
    public let evidence: [Evidence]

    public init(id: String, confirmed: Bool, note: String? = nil, evidence: [Evidence] = []) {
        self.id = id
        self.confirmed = confirmed
        self.note = note
        self.evidence = evidence
    }
}
