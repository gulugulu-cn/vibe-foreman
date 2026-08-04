import Foundation
import HubCore
import HubIPC
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
    private var server: HubSocketServer?

    /// 触发灵动岛闯入。
    public var onIntrusion: ((IntrusionEvent) -> Void)?
    /// 需要弹审批面板。
    public var onApprovalNeeded: (() -> Void)?
    /// 需要弹交互作答卡（选择题 / 计划审批）。
    public var onPromptNeeded: (() -> Void)?

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
        projects: ProjectStore
    ) {
        self.store = store
        self.approvals = approvals
        self.prompts = prompts
        self.notifications = notifications
        self.projects = projects
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

    private nonisolated func handle(_ event: HookEvent) -> HookDecision {
        switch event.kind {
        case .stop:
            Task { @MainActor in self.handleStop(event) }
            return .allow

        case .notification:
            Task { @MainActor in self.handleNotification(event) }
            return .allow

        case .sessionEnd:
            Task { @MainActor in self.store.refresh() }
            return .allow

        case .preToolUse:
            return handlePreToolUseSynchronously(event)
        }
    }

    @MainActor
    private func handleStop(_ event: HookEvent) {
        store.refresh()

        let project = projects.projectName(forPath: event.cwd) ?? event.fallbackProjectName
        let session = store.sessions.first { $0.sessionId == event.sessionId }
        let title = session?.name ?? project

        // 正文用 Claude 自己的最终回复，替掉旧实现那 5 条随机中文文案
        // （"搞定了，来看看" 之类，信息量为零，用户还得切过去才知道干了什么）。
        let body = Self.summarize(event.lastAssistantMessage) ?? "完成了一轮回复"

        notifications.post(title: "✅ \(title)", body: body, sessionId: event.sessionId)

        if allowIntrusion(for: event.sessionId) {
            onIntrusion?(
                IntrusionEvent(
                    kind: .finished, sessionId: event.sessionId,
                    title: title, detail: "\(project) · \(body)"
                )
            )
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
