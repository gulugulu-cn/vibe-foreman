import Foundation
import HubIPC

/// 一条待作答的交互请求（选择题 / 计划审批）。
public struct AgentPromptRequest: Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let projectName: String
    public let cwd: String
    public let payload: AgentPromptPayload
    /// 发起这次调用的 hook 进程，用于 orphan 检测（同 ApprovalRequest.clientPid）。
    public let clientPid: pid_t
    public let createdAt: Date

    public init(
        id: String, sessionId: String, projectName: String, cwd: String,
        payload: AgentPromptPayload, clientPid: pid_t = 0, createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.projectName = projectName
        self.cwd = cwd
        self.payload = payload
        self.clientPid = clientPid
        self.createdAt = createdAt
    }
}

/// 岛上作答（选择题 / 计划审批）的协调器。
///
/// 结构照 `ApprovalCoordinator`（queue + continuation + 超时 + orphan sweep），
/// 但**故意不合并进去**：两边的超时方向相反 ——
///
/// - 审批：超时 **deny**。它是唯一的安全刹车，放行不可逆。
/// - 交互卡：超时 **allow（不输出决策）**。这不是放行危险操作，而是把问题
///   交还给终端的原生对话框：Claude 走正常权限流程，终端照常弹框，
///   用户什么都没损失。给安全刹车塞一条 fail-open 分支才是真风险。
@Observable
@MainActor
public final class AgentPromptCoordinator {

    public private(set) var queue: [AgentPromptRequest] = []
    public var current: AgentPromptRequest? { queue.first }

    private var pending: [String: CheckedContinuation<HookDecision, Never>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var orphanSweep: Task<Void, Never>?

    /// 可注入：测试要用 0.1s 验证"超时方向是 allow"。
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = HookTimeouts.promptDecision) {
        self.timeout = timeout
    }

    // MARK: - hook 侧入口

    /// 提交一次交互请求并等待作答。**会阻塞调用方直到有结果。**
    public func requestDecision(for request: AgentPromptRequest) async -> HookDecision {
        queue.append(request)

        let task = Task { [weak self, timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            // 到点交还终端：不输出决策，原生对话框正常出现。
            await self?.resolve(id: request.id, decision: .allow)
        }
        timeoutTasks[request.id] = task

        return await withCheckedContinuation { continuation in
            pending[request.id] = continuation
        }
    }

    // MARK: - UI 侧动作

    /// 选择题：点选一个选项（单题快捷通道）。用 deny + reason 把答案回传给
    /// Claude —— PreToolUse 没有"替用户作答"的通道，deny 的 reason 是唯一能
    /// 把文本送回模型的口子。文案写成指令式，防止 Claude 把它当失败重新提问。
    public func choose(_ request: AgentPromptRequest, option: AgentQuestion.Option) {
        resolve(
            id: request.id,
            decision: HookDecision(
                verdict: .deny,
                reason: "用户已在 Vibe Foreman 上选择：\(option.label)。请按这个选择继续，不要重复提问。"
            )
        )
    }

    /// 多题 / 多选：把每道题的作答一并回传。
    public func submitAnswers(_ request: AgentPromptRequest, answers: [AgentAnswer]) {
        let joined = answers.map(\.line).joined(separator: "；")
        resolve(
            id: request.id,
            decision: HookDecision(
                verdict: .deny,
                reason: "用户已在 Vibe Foreman 上作答 —— \(joined)。请按这些选择继续，不要重复提问。"
            )
        )
    }

    /// 计划审批 / 进入计划模式：同意。显式输出 allow，跳过终端确认直接生效。
    public func approvePlan(_ request: AgentPromptRequest) {
        resolve(
            id: request.id,
            decision: HookDecision(verdict: .allow, explicitAllow: true)
        )
    }

    /// 计划审批：驳回。
    public func rejectPlan(_ request: AgentPromptRequest) {
        resolve(
            id: request.id,
            decision: HookDecision(
                verdict: .deny,
                reason: "用户在 Vibe Foreman 上驳回了这份计划，请调整后重新提出。"
            )
        )
    }

    /// 进入计划模式：拒绝。
    public func rejectEnterPlan(_ request: AgentPromptRequest) {
        resolve(
            id: request.id,
            decision: HookDecision(
                verdict: .deny,
                reason: "用户不同意进入计划模式，请按当前方式继续。"
            )
        )
    }

    /// 「去终端回答」/ 降级卡：不输出决策，终端原生对话框接管。
    public func passthrough(_ request: AgentPromptRequest) {
        resolve(id: request.id, decision: .allow)
    }

    // MARK: - 通知侧入口（权限确认框）

    /// 免等待入队：权限确认框来自 Notification hook，没有阻塞方在等结果，
    /// 卡片的"结果"是往终端注入按键。超时到点只是把卡收掉，终端框还在。
    public func enqueue(_ request: AgentPromptRequest) {
        queue.append(request)
        let task = Task { [weak self, timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.resolve(id: request.id, decision: .allow)
        }
        timeoutTasks[request.id] = task
    }

    /// 收掉一张卡（免等待卡答完 / 会话自己恢复忙碌时用）。对阻塞卡等价于 passthrough。
    public func dismiss(_ request: AgentPromptRequest) {
        resolve(id: request.id, decision: .allow)
    }

    /// 同一个会话的权限框已经在排队了吗？（通知可能重发，别弹两张一样的卡。）
    public func hasPermissionCard(for sessionId: String) -> Bool {
        queue.contains {
            guard case .permission = $0.payload else { return false }
            return $0.sessionId == sessionId
        }
    }

    // MARK: - 僵尸清理

    /// 同 `ApprovalCoordinator.startOrphanSweep`：发起方（hubctl）死了就清卡。
    /// 结果用 allow —— 反正没人收，中性的那侧。
    public func startOrphanSweep() {
        orphanSweep?.cancel()
        orphanSweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.dropOrphans()
            }
        }
    }

    public func stopOrphanSweep() {
        orphanSweep?.cancel()
        orphanSweep = nil
    }

    private func dropOrphans() {
        for request in queue where request.clientPid > 0 {
            guard kill(request.clientPid, 0) != 0, errno == ESRCH else { continue }
            resolve(id: request.id, decision: .allow)
        }
    }

    private func resolve(id: String, decision: HookDecision) {
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil

        // 先出队再看有没有等待方：权限卡（enqueue 进来的）没有 continuation，
        // 但同样要能被收掉 —— 出队不能藏在 continuation 的 guard 后面。
        queue.removeAll { $0.id == id }
        pending.removeValue(forKey: id)?.resume(returning: decision)
    }
}
