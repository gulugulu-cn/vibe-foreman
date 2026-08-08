import Foundation
import HubCore
import HubIPC
import HubProbe
import HubProjects

/// 把 hook 事件接到 UI 上。
///
/// 链路：`hubctl` → Unix socket → 这里 → 通知 / 灵动岛闯入 / 审批。
@MainActor
public final class HookCoordinator {

    private let store: SessionStore
    private let approvals: ApprovalCoordinator
    private let prompts: AgentPromptCoordinator
    private let notifications: HubNotificationCenter
    private let projects: ProjectStore
    private let acceptance: AcceptanceStore
    private var server: HubSocketServer?

    /// 每类 hook 最后一次收到事件的时间。设置页用它显示通道健康度 ——
    /// 「配好了」和「真的在通」是两回事，只有后者能证明链路活着。
    public let channels = HookChannelMonitor()

    private let dedup = HookDedup()
    private let extractor = AcceptanceExtractor()
    private let auditor = AcceptanceAuditor()
    /// 读 Claude 自己的 todo（`~/.claude/tasks/`）。零成本，不调模型。
    private let tasks = TaskStateReader()
    /// 正在复核中的项目。同一个项目不并发跑，理由同 `extracting`。
    private var auditing: Set<String> = []
    /// 正在拆解中的项目。同一个项目的拆解不并发跑 —— 两次并发会拿到同一份
    /// 原话缓冲，把同一批要点拆两遍（去重能挡住重复入库，但白烧一次额度）。
    private var extracting: Set<String> = []

    /// 触发灵动岛闯入。
    public var onIntrusion: ((IntrusionEvent) -> Void)?
    /// 需要弹审批面板。
    public var onApprovalNeeded: (() -> Void)?
    /// 需要弹交互作答卡（选择题 / 计划审批）。
    public var onPromptNeeded: (() -> Void)?
    /// 某个会话收工了。盯梢靠它做到「一停就跟上」——
    /// 轮询要 90 秒才确认，而 Hook 在收工那一刻就知道。
    public var onSessionStopped: ((String, String, String?) -> Void)?

    /// 闯入防轰炸：记录每个会话上次闯入的时间。
    ///
    /// 9 个会话同时收工的时候这条至关重要 —— 不限流的话岛会连续膨胀九次，
    /// 从"有用的提醒"变成"必须关掉的骚扰"。
    private var lastIntrusionAt: [String: Date] = [:]
    private let intrusionCooldown: TimeInterval = 60

    private let classifier = RiskClassifier()

    public init(
        store: SessionStore,
        approvals: ApprovalCoordinator,
        prompts: AgentPromptCoordinator,
        notifications: HubNotificationCenter,
        projects: ProjectStore,
        acceptance: AcceptanceStore
    ) {
        self.store = store
        self.approvals = approvals
        self.prompts = prompts
        self.notifications = notifications
        self.projects = projects
        self.acceptance = acceptance
    }

    public func start() {
        let server = HubSocketServer { [weak self] event in
            // 这个闭包跑在 socket 的工作线程上。preToolUse 要同步返回决策，
            // 而决策来自 MainActor 上的 UI，所以用信号量把异步结果桥回来。
            // 阻塞的是这条连接自己的线程，不影响其他连接。
            guard let self else { return .allow }
            return self.handle(event)
        }

        do {
            try server.start()
            self.server = server
            NSLog("[ClaudeHub] hook socket 已监听：\(HubSocket.path)")
        } catch {
            NSLog("[ClaudeHub] hook socket 启动失败：\(error) —— hook 将全部放行")
        }
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    // MARK: - 事件分发

    /// 去重 → 分发。
    ///
    /// 去重必须包在最外层：hook 配置是叠加的（全局 + 项目级都会跑一遍，本机实测确认），
    /// 同一个事件进来两次。详见 `HookDedup`。
    private nonisolated func handle(_ event: HookEvent) -> HookDecision {
        Task { @MainActor in self.channels.record(event.kind) }

        guard let key = HookDedup.key(for: event) else { return dispatch(event) }

        switch dedup.begin(key, waitForDecision: event.kind == .preToolUse) {
        case .duplicate(let decision):
            HubLog.ipc.notice("去重：\(event.kind.rawValue, privacy: .public) 重复事件")
            return decision ?? .allow
        case .first:
            let decision = dispatch(event)
            dedup.finish(key, decision: decision)
            return decision
        }
    }

    private nonisolated func dispatch(_ event: HookEvent) -> HookDecision {
        switch event.kind {
        case .stop:
            return handleStopSynchronously(event)

        case .notification:
            Task { @MainActor in self.handleNotification(event) }
            return .allow

        case .sessionEnd:
            Task { @MainActor in self.store.refresh() }
            return .allow

        case .userPromptSubmit:
            Task { @MainActor in self.handleUserPrompt(event) }
            return .allow

        case .sessionStart:
            Task { @MainActor in self.store.refresh() }
            return .allow

        case .postToolUse:
            Task { @MainActor in self.handlePostToolUse(event) }
            return .allow

        case .subagentStop, .preCompact:
            // 目前只用来点亮通道健康度（上面 handle 里已经记过）。
            // preCompact 之后 Claude 会忘掉一大段上下文 —— 而清单不会，
            // 这正是它存在的意义，不需要额外动作。
            return .allow

        case .preToolUse:
            return handlePreToolUseSynchronously(event)
        }
    }

    /// 收工。**阻塞式** —— hubctl 在等"要不要把验收清单塞回去"。
    ///
    /// ## 兜底方向和审批链路相反，这是本方法最要紧的一条
    ///
    /// `handlePreToolUseSynchronously` 超时兜底是 **deny**（安全刹车）。
    /// 这里超时兜底必须是 **allow = 不拦**。写反的话 Hub 一出问题，
    /// 所有会话就再也收不了工 —— 比"少提醒一次验收"严重得多。
    ///
    /// 3 秒足够：该不该拦是查内存里的清单，毫秒级就有答案，
    /// 这 3 秒纯粹是给 MainActor 排队留的余量。
    private nonisolated func handleStopSynchronously(_ event: HookEvent) -> HookDecision {
        let semaphore = DispatchSemaphore(value: 0)
        // 同 handlePreToolUseSynchronously：只有下面的 Task 写、wait 之后才读。
        nonisolated(unsafe) var result = HookDecision.allow

        Task { @MainActor in
            result = self.handleStop(event)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + HookTimeouts.stopBridge) == .timedOut {
            HubLog.ipc.error("收工桥接超时 —— 放行（绝不能因为 Hub 慢就让会话停不下来）")
            return .allow
        }
        return result
    }

    @MainActor
    private func handleStop(_ event: HookEvent) -> HookDecision {
        store.refresh()

        let path = AcceptanceStore.projectPath(forCWD: event.cwd, projects: projects)

        // 把 Claude 自己列的 todo 并进清单。零成本，读本地 JSON。
        collectAssistantTasks(from: event, projectPath: path)

        // 先收自查回答，再决定拦不拦。
        //
        // 顺序不能反：上一轮拦下来之后 Claude 的回答就在这条事件的
        // lastAssistantMessage 里，先收下来，这一轮的清单才是最新的。
        collectClaims(from: event, projectPath: path)

        let decision = interceptDecision(for: event, projectPath: path)

        let project = projects.projectName(forPath: event.cwd) ?? event.fallbackProjectName
        let session = store.sessions.first { $0.sessionId == event.sessionId }
        let title = session?.name ?? project

        // 正文用 Claude 自己的最终回复，替掉旧实现那 5 条随机中文文案
        // （"搞定了，来看看" 之类，信息量为零，用户还得切过去才知道干了什么）。
        let body = Self.summarize(event.lastAssistantMessage) ?? "完成了一轮回复"

        // 被拦下来的这一轮不是"收工"，别发完成通知 —— Claude 马上还要再跑一轮，
        // 现在弹「✅ 完成了」是在骗用户。
        guard decision.verdict != .deny else {
            HubLog.app.notice("验收守望：拦下 \(title, privacy: .public) 的收工，要求逐条核对")
            return decision
        }

        // 收工事件立刻告诉盯梢。**这是「反应力」的关键**：
        // 轮询那条路要 45 秒一轮 × 连续两次确认 = 最少 90 秒才会追问，
        // 而 Hub 在这一刻就已经知道它停了。
        // 把它刚说的那段话一起带上 —— 规划器要靠它想出针对性的问题。
        onSessionStopped?(event.sessionId, path, event.lastAssistantMessage)

        notifications.post(title: "✅ \(title)", body: body, sessionId: event.sessionId)

        if allowIntrusion(for: event.sessionId) {
            onIntrusion?(
                IntrusionEvent(
                    kind: .finished, sessionId: event.sessionId,
                    title: title, detail: "\(project) · \(body)"
                )
            )
        }
        return decision
    }

    /// 该不该拦这一次收工。
    @MainActor
    private func interceptDecision(for event: HookEvent, projectPath: String) -> HookDecision {
        // Claude 已经因为 Stop hook 在续跑了 —— 绝不能再拦。
        //
        // 这是**第二道**。真正的保证是下面 disarmAndShouldIntercept 里的上膛机制，
        // 因为这个字段在本机没验证过，不同 CLI 版本给不给都不确定。
        guard event.stopHookActive != true else { return .allow }

        guard acceptance.disarmAndShouldIntercept(
            sessionId: event.sessionId, projectPath: projectPath
        ) else { return .allow }

        guard let text = acceptance.injectionText(for: projectPath) else { return .allow }

        return HookDecision(verdict: .deny, reason: text)
    }

    /// 把 Claude 自己列的 todo 并进清单。
    ///
    /// ## 为什么要收它
    ///
    /// 这份清单**不能当基线** —— 用户需求翻译成它的那一步就已经丢东西了。
    /// 但先前我把它整个排除了，而用户一眼看出问题：清单里全是他说过的话，
    /// **AI 自己答应要做的事一条都没有**。
    ///
    /// 「它自己列了 6 项，做完 3 项就说完事了」是遗漏最直接的证据，
    /// 而这类承诺不在用户原话里，别处根本抓不到。所以收，但单独标成「AI 计划」。
    ///
    /// ## 勾掉的进「待复核」，不是「已验收」
    ///
    /// 一开始我把 `done` 的直接记成 `.confirmed`，理由是"勾状态是它边干边写进
    /// 文件的，比嘴上说可信"。**这个理由站不住。** 它勾自己的框和它嘴上说
    /// "做完了"是同一性质的东西 —— 都是声明，都没有外部证据。
    /// 拿它自己勾的框当证据，正是这整个功能要防的事，我在这儿又犯了一次。
    ///
    /// 所以勾掉的落到 `.claimed`，证据记成 `.claimed(...)`（`isProof == false`），
    /// 然后由旁路复核拿真实 git diff 去判 confirmed / disputed。
    /// 用户的原话：「他勾掉的到底有没有做」——这个问题只有 diff 能回答。
    @MainActor
    private func collectAssistantTasks(from event: HookEvent, projectPath: String) {
        let tasks = tasks.readTasks(sessionId: event.sessionId)
        guard !tasks.isEmpty else { return }

        // 基线：这些要点是这一刻入库的，diff 从这里往后算。
        // 缺了它复核只能拿未提交的改动去比，结论会全是噪音。
        let baseline = GitDiff.head(projectPath)

        acceptance.merge(
            tasks.map { task in
                AcceptanceItem(
                    text: task.subject,
                    origin: .assistantTask,
                    status: task.done ? .claimed : .open,
                    evidence: task.done ? [.claimed("Claude 在自己的 todo 里勾了完成")] : [],
                    sourceSessionId: event.sessionId,
                    baselineCommit: baseline
                )
            },
            into: projectPath
        )
        // 已有的那些也要跟着更新状态 —— 上一轮进来时还没做完的，
        // 这一轮可能已经勾掉了。不同步的话它们会永远挂在「未验收」。
        acceptance.syncAssistantTasks(
            done: tasks.filter(\.done).map(\.subject), in: projectPath
        )
    }

    /// 收下 Claude 上一轮的逐条自查回答。
    ///
    /// 解析不出来就什么都不做 —— 它很可能是直接去补做遗漏项了（那其实是好事），
    /// 或者干脆没按格式答。这两种情况都退回旁路复核，不该报错也不该清状态。
    @MainActor
    private func collectClaims(from event: HookEvent, projectPath: String) {
        guard let message = event.lastAssistantMessage,
              let claims = Self.parseClaims(message), !claims.isEmpty
        else { return }
        acceptance.applyClaims(claims, in: projectPath)
        HubLog.app.notice("验收守望：收下 \(claims.count, privacy: .public) 条自查回答")
        scheduleAudit(projectPath: projectPath, sessionId: event.sessionId)
    }

    /// 拿真实 git diff 复核所有「待复核」项。
    ///
    /// 自查治的是「忘」（把用户的原始要求重新摆到它眼前），但自查仍然是它在说
    /// 自己，治不了「骗」，也治不了「它真心以为自己做了」。这一步读代码里到底
    /// 有没有对应改动，治的是后者。
    @MainActor
    private func scheduleAudit(projectPath: String, sessionId: String) {
        guard !auditing.contains(projectPath) else { return }

        let items = acceptance.ledger(for: projectPath).items
            .filter { $0.status == .claimed && !$0.isSettledByUser }
        guard !items.isEmpty else { return }

        let subjects = items.map {
            AuditSubject(
                id: $0.id, text: $0.text, acceptance: $0.acceptance,
                claimed: $0.latestClaim ?? "（没说）"
            )
        }
        // 取最早的基线：要点是陆续入库的，用最晚那个会把先入库要点对应的改动
        // 全部排除在 diff 之外，于是它们必然被判成「代码里找不到」。
        let since = items.compactMap(\.baselineCommit).min()
        // Hub 自己通过 PostToolUse 看到的被改文件 —— 第一手，不经 Claude 转述。
        let touched = acceptance.touchedFiles(sessionId: sessionId)

        auditing.insert(projectPath)
        let auditor = self.auditor

        Task.detached(priority: .utility) {
            let results = await auditor.audit(
                subjects: subjects, cwd: projectPath, since: since, touchedFiles: touched
            )

            await MainActor.run {
                self.auditing.remove(projectPath)
                // nil = 这次没跑成。**什么都别改** —— 把"复核失败"当成"存疑"
                // 会让模型每抽风一次就诬告一批要点。
                guard let results, !results.isEmpty else { return }

                self.acceptance.applyAudit(
                    results.map { result in
                        AcceptanceVerdict(
                            id: result.id,
                            confirmed: result.confirmed,
                            note: result.note,
                            evidence: Self.evidence(for: result, cwd: projectPath, since: since)
                        )
                    },
                    in: projectPath
                )
                let disputed = results.filter { !$0.confirmed }.count
                HubLog.app.notice("""
                验收复核：\(results.count, privacy: .public) 条，\
                存疑 \(disputed, privacy: .public) 条
                """)
            }
        }
    }

    /// 把复核认定的文件换算成带行数的证据。
    ///
    /// 行数取自 `git diff --numstat`，**不是模型报的** —— 模型只负责说
    /// "这条要点对应哪几个文件"，具体改了多少行由 git 自己回答。
    /// 让模型报数字等于又给了一次编造的机会。
    private nonisolated static func evidence(
        for result: AuditResult, cwd: String, since: String?
    ) -> [Evidence] {
        guard !result.files.isEmpty else { return [] }
        let changes = GitDiff.numstat(cwd, since: since)
        return result.files.compactMap { path in
            guard let change = changes.first(where: { $0.path.hasSuffix(path) || path.hasSuffix($0.path) })
            else { return nil }
            return .diff(path: change.path, added: change.added, removed: change.removed)
        }
    }

    /// 从 Claude 的回复里挖出自查 JSON。
    ///
    /// 走 `ModelOutput.extractJSONObject` 而不是直接解析：模型在 JSON 前后
    /// 各写一段话是常态（"我核对了一遍：{…} 需要我继续吗？"），
    /// 而这里它是在一段长对话的末尾被要求输出 JSON 的，更容易加客套话。
    nonisolated static func parseClaims(_ message: String) -> [AcceptanceClaim]? {
        guard let object = ModelOutput.extractJSONObject(message),
              let raw = object["items"] as? [[String: Any]]
        else { return nil }

        return raw.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return AcceptanceClaim(
                id: id,
                // done 缺失或不是**真正的布尔**时按没做算。方向是刻意的：
                // 把含糊不清当成"做完了"，等于给虚报开了个免检通道。
                done: Self.strictlyTrue(item["done"]),
                evidence: (item["evidence"] as? String) ?? ""
            )
        }
    }

    /// 只有 JSON 里字面写的 `true` 才算数。
    ///
    /// **不能用 `as? Bool`。** JSONSerialization 把 `true` 和 `1` 都解成 NSNumber，
    /// 而 NSNumber 到 Bool 的桥接对 `1` 是成立的 —— 于是 `{"done":1}` 会被判成
    /// 做完了。测试抓到过：模型只要把 done 写成数字就能绕过"含糊按没做算"。
    ///
    /// CFBoolean 和 CFNumber 是不同的 CF 类型，按类型 ID 判才分得开。
    nonisolated static func strictlyTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return false }
        return number.boolValue
    }

    /// 用户提交了一句话。
    ///
    /// 这个 handler 干两件事，**都必须极快**（这条 hook 挡在用户和 Claude 之间）：
    /// 1. 把原话原样记进清单缓冲 —— 零成本，不调模型；
    /// 2. 给这个会话的拦截「上膛」。
    ///
    /// 第 2 件是全案防死循环的结构性保证：`UserPromptSubmit` 是**唯一**的上膛入口，
    /// 而它只在用户敲回车时触发。Claude 没有任何路径能给自己上膛，
    /// 所以「拦一次 → 它回一轮 → 又拦」这个循环构造不出来。详见 `AcceptanceStore`。
    ///
    /// 拆解是异步的：它要花几秒到几十秒，绝不能挡在这里。等 Claude 干完活
    /// （通常几分钟），拆解早就完成了。
    @MainActor
    private func handleUserPrompt(_ event: HookEvent) {
        acceptance.arm(sessionId: event.sessionId)

        guard let text = event.promptText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }

        let path = AcceptanceStore.projectPath(forCWD: event.cwd, projects: projects)
        acceptance.recordPrompt(
            RawPrompt(text: text, sessionId: event.sessionId), in: path
        )
        scheduleExtraction(projectPath: path, plan: nil)
    }

    /// 工具跑完了。
    ///
    /// **这是"实际功能证明"最便宜的一半。** Write / Edit 之后 Hub 第一手知道
    /// 哪个文件被改了 —— 不用回头问 Claude"你改了什么"，而转述那一步正是
    /// 失真发生的地方。这些文件后面会交给旁路复核去和清单对号。
    @MainActor
    private func handlePostToolUse(_ event: HookEvent) {
        guard let toolName = event.toolName, Self.editingTools.contains(toolName),
              let path = event.toolSummary, path.hasPrefix("/")
        else { return }
        acceptance.recordTouchedFile(path, sessionId: event.sessionId)
    }

    /// 会改代码的工具。`toolSummary` 对这几个提取的正是 `file_path`。
    static let editingTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// 把缓冲里的原话（和可选的计划全文）拆成要点，合并进清单。
    @MainActor
    private func scheduleExtraction(projectPath: String, plan: String?) {
        guard !extracting.contains(projectPath) else { return }

        let ledger = acceptance.ledger(for: projectPath)
        let prompts = ledger.rawPrompts
        guard !prompts.isEmpty || plan != nil else { return }
        let existing = ledger.items.map(\.text)
        // 只清掉这次真正喂进去的那些。拆解期间用户可能又说了话，
        // 按时间截断而不是整个清空，才不会把新说的一起丢掉。
        let cutoff = prompts.last?.at ?? Date()

        extracting.insert(projectPath)
        let extractor = self.extractor

        Task.detached(priority: .utility) {
            // 在后台线程读 HEAD：它要 fork 一个 git 进程，别占着 MainActor。
            let baseline = GitDiff.head(projectPath)

            let points: [ExtractedPoint]?
            if await extractor.shouldExtract(prompts: prompts, plan: plan) {
                points = await extractor.extract(
                    prompts: prompts, plan: plan, existing: existing
                )
            } else {
                // 太短、或功能没开 —— 不是失败，原话继续攒着等下一次。
                points = nil
            }

            await MainActor.run {
                self.extracting.remove(projectPath)
                // nil = 这次没跑成。**原话必须留着** —— 它是这个功能唯一的基线来源，
                // 一次失败就丢掉的话，用户说过的要求就永远找不回来了。
                guard let points else { return }

                self.acceptance.clearPrompts(upTo: cutoff, in: projectPath)
                guard !points.isEmpty else { return }
                self.acceptance.merge(
                    points.map {
                        AcceptanceItem(
                            text: $0.text,
                            acceptance: $0.acceptance,
                            origin: $0.inferred ? .inferred : (plan != nil ? .plan : .userPrompt),
                            // 入库这一刻的 HEAD 就是这条要点的 diff 起点。
                            // 少了它，复核时无从回答"这条要点之后代码变了什么"，
                            // 只能拿整个仓库历史去比，噪音大到没法用。
                            baselineCommit: baseline
                        )
                    },
                    into: projectPath
                )
                HubLog.app.notice(
                    "验收清单：\(projectPath, privacy: .public) 新增 \(points.count, privacy: .public) 条"
                )
            }
        }
    }

    @MainActor
    private func handleNotification(_ event: HookEvent) {
        store.refresh()

        let project = projects.projectName(forPath: event.cwd) ?? event.fallbackProjectName
        let session = store.sessions.first { $0.sessionId == event.sessionId }
        let title = session?.name ?? project
        let needsUser = event.notificationType == "permission_prompt"
            || event.notificationType == "idle_prompt"
            || event.notificationType == "elicitation_dialog"
            || event.notificationType == "agent_needs_input"

        notifications.post(
            title: needsUser ? "⚠️ \(title)" : title,
            body: event.message ?? "需要你处理",
            sessionId: event.sessionId
        )

        // 权限确认框（"Do you want to create xxx?"）弹**可作答的卡**而不是横幅：
        // 横幅只能提醒"有个框在等你"，卡能直接把 1 / Esc 发过去。
        // 答案走终端按键注入，不走 hook 回传 —— 这个 hook 是 async 的，早就返回了。
        if event.notificationType == "permission_prompt" {
            guard !prompts.hasPermissionCard(for: event.sessionId) else { return }
            prompts.enqueue(
                AgentPromptRequest(
                    id: event.requestId,
                    sessionId: event.sessionId,
                    projectName: project,
                    cwd: event.cwd,
                    payload: .permission(message: event.message ?? "Claude 在等你授权"),
                    // 发起方 hubctl 发完通知就退出了，绝不能让 orphan sweep
                    // 按"发起方已死"把这张卡清掉 —— 0 = 不做存活检测。
                    clientPid: 0
                )
            )
            onPromptNeeded?()
            return
        }

        guard needsUser, allowIntrusion(for: event.sessionId) else { return }
        onIntrusion?(
            IntrusionEvent(
                kind: .needsInput, sessionId: event.sessionId,
                title: title, detail: "\(project) · \(event.message ?? "等待你的输入")"
            )
        )
    }

    /// PreToolUse 必须**同步**返回 —— hubctl 那头在等这条连接的应答。
    ///
    /// 用信号量把 MainActor 上的异步审批结果桥回当前线程。这是少数几个
    /// 用信号量阻塞是正确做法的场景：调用方本来就是一条专用的连接线程，
    /// 它的全部职责就是等这个结果。
    private nonisolated func handlePreToolUseSynchronously(_ event: HookEvent) -> HookDecision {
        // 交互类工具（选择题 / 计划审批）在 risk 判定之前分流：它们的
        // tool_input 里没有 command / path，走风险链路会被判成 normal
        // 直接放行 —— 岛上什么都不弹，这正是要修的 bug。
        if let toolName = event.toolName, AgentPromptPayload.interactiveTools.contains(toolName) {
            return handleAgentPromptSynchronously(event, toolName: toolName)
        }

        let risk = classifier.classify(toolName: event.toolName, summary: event.toolSummary)
        guard risk != .normal else { return .allow }

        guard classifier.shouldIntercept(risk) else {
            // dangerous 档默认只记录不拦截：用户全局开着 auto + skip-permissions，
            // 拦上这一档每天要弹 3–8 次，结果必然是他把整个功能关掉。
            Task { @MainActor in
                let project = self.projects.projectName(forPath: event.cwd)
                    ?? event.fallbackProjectName
                self.approvals.recordWithoutIntercepting(
                    projectName: project,
                    toolName: event.toolName ?? "?",
                    command: event.toolSummary ?? "",
                    risk: risk
                )
            }
            return .allow
        }

        let semaphore = DispatchSemaphore(value: 0)
        // nonisolated(unsafe) 是安全的：只有下面的 Task 写、只有 wait 之后才读，
        // 信号量提供了 happens-before 关系。
        nonisolated(unsafe) var result = HookDecision.allow

        Task { @MainActor in
            let project = self.projects.projectName(forPath: event.cwd)
                ?? event.fallbackProjectName
            let request = ApprovalRequest(
                id: event.requestId,
                sessionId: event.sessionId,
                projectName: project,
                cwd: event.cwd,
                toolName: event.toolName ?? "?",
                command: event.toolSummary ?? "(无参数)",
                risk: risk,
                clientPid: event.clientPid ?? 0
            )
            self.onApprovalNeeded?()
            result = await self.approvals.requestDecision(for: request)
            semaphore.signal()
        }

        // 见 HookTimeouts 的超时阶梯：这一层要比 ApprovalCoordinator 的
        // 用户决策超时长，但比 hubctl 的读超时短。
        if semaphore.wait(timeout: .now() + HookTimeouts.serverBridge) == .timedOut {
            HubLog.ipc.error("审批桥接超时，按拒绝处理")
            return HookDecision(verdict: .deny, reason: "Claude Hub 审批超时")
        }
        HubLog.ipc.notice("用户决策：\(result.verdict.rawValue, privacy: .public)")
        return result
    }

    /// 交互作答（选择题 / 计划审批）的同步桥。结构同上，但**兜底方向相反**：
    /// 这条链路的一切异常都必须落在 allow（不输出决策）—— 那只是把问题
    /// 交还给终端的原生对话框，用户什么都没损失；落在 deny 会把 Claude 的
    /// 正常提问变成一次莫名其妙的失败。
    private nonisolated func handleAgentPromptSynchronously(
        _ event: HookEvent, toolName: String
    ) -> HookDecision {
        let semaphore = DispatchSemaphore(value: 0)
        // 同 handlePreToolUseSynchronously：只有下面的 Task 写、wait 之后才读。
        nonisolated(unsafe) var result = HookDecision.allow

        Task { @MainActor in
            let project = self.projects.projectName(forPath: event.cwd)
                ?? event.fallbackProjectName
            let payload = AgentPromptPayload.parse(
                toolName: toolName, inputJSON: event.toolInputJSON
            ) ?? .complex(hint: "Claude 在等你的输入")
            let request = AgentPromptRequest(
                id: event.requestId,
                sessionId: event.sessionId,
                projectName: project,
                cwd: event.cwd,
                payload: payload,
                clientPid: event.clientPid ?? 0
            )
            self.onPromptNeeded?()
            result = await self.prompts.requestDecision(for: request)
            semaphore.signal()

            // 计划全文进验收清单 —— 这是权威性最高的基线来源（用户明确批准过的）。
            //
            // 两个时机上的讲究：
            // - **在 signal 之后**：拆解要起一个 claude 子进程，绝不能拖着 hubctl 等；
            // - **只在没被驳回时**：驳回的计划不是基线，是被否掉的方案。
            //   passthrough（用户跑去终端自己确认）也算数 —— 那种情况 Hub 看不到
            //   最终结果，但用户既然没在岛上按驳回，按批准处理比丢掉更合理。
            if case .plan(let text) = payload, result.verdict != .deny {
                self.scheduleExtraction(
                    projectPath: AcceptanceStore.projectPath(
                        forCWD: event.cwd, projects: self.projects
                    ),
                    plan: text
                )
            }
        }

        if semaphore.wait(timeout: .now() + HookTimeouts.serverBridge) == .timedOut {
            HubLog.ipc.error("交互卡桥接超时，交还终端处理")
            return .allow
        }
        HubLog.ipc.notice("交互作答：\(result.verdict.rawValue, privacy: .public)")
        return result
    }

    // MARK: - 辅助

    private func allowIntrusion(for sessionId: String) -> Bool {
        let now = Date()
        if let last = lastIntrusionAt[sessionId], now.timeIntervalSince(last) < intrusionCooldown {
            return false
        }
        lastIntrusionAt[sessionId] = now
        return true
    }

    /// 把 Claude 的最终回复压成一行通知正文。
    static func summarize(_ message: String?) -> String? {
        guard let message else { return nil }
        let cleaned = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= 90 { return cleaned }
        return String(cleaned.prefix(88)) + "…"
    }
}
