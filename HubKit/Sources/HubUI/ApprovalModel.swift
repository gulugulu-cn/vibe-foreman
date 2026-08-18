import Foundation
import HubIPC

/// 一条待决策的审批请求。
public struct ApprovalRequest: Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let projectName: String
    public let cwd: String
    public let toolName: String
    public let command: String
    public let risk: RiskLevel
    public let createdAt: Date
    /// 发起这次调用的 hook 进程。用来检测对端是否还活着，见
    /// `ApprovalCoordinator.startOrphanSweep()`。
    public let clientPid: pid_t

    public init(
        id: String, sessionId: String, projectName: String, cwd: String,
        toolName: String, command: String, risk: RiskLevel,
        clientPid: pid_t = 0, createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.projectName = projectName
        self.cwd = cwd
        self.toolName = toolName
        self.command = command
        self.risk = risk
        self.clientPid = clientPid
        self.createdAt = createdAt
    }

    /// L3 的「允许」需要按住确认，L2 只需要等解锁。
    public var requiresHoldToConfirm: Bool { risk == .irreversible }
}

/// 审批日志的一条记录。这份数据现在完全没留存，但它很值钱 ——
/// 用户看一周就知道该不该把 `dangerous` 一档也开启拦截。
public struct ApprovalLogEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let projectName: String
    public let toolName: String
    public let command: String
    public let risk: RiskLevel
    public let verdict: String
    /// 是否真的弹了岛。`dangerous` 默认只记录不拦截，这时是 false。
    public let intercepted: Bool
}

/// 岛上审批的协调器。
///
/// hook 线程会在 `await` 上阻塞直到用户点击或超时，所以这里用 continuation
/// 而不是轮询 —— hook 那边每多等 100ms 都是用户在等。
@Observable
@MainActor
public final class ApprovalCoordinator {

    /// 当前排队中的请求。第一条显示在岛上，其余用堆叠卡片暗示。
    public private(set) var queue: [ApprovalRequest] = []
    public private(set) var log: [ApprovalLogEntry] = []

    /// 拦截门槛。默认只拦不可逆操作，见 RiskClassifier 里的理由。
    public var interceptThreshold: RiskLevel = .irreversible

    private var pending: [String: CheckedContinuation<HookDecision, Never>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// 用户决策的时限。到点自动拒绝。
    ///
    /// 默认 deny 而不是 allow：用户全局开着 auto + skip-permissions，这是唯一的刹车。
    /// 而且 deny 是可恢复的（Claude 会告诉用户被拒了，重跑即可），allow 不可逆。
    ///
    /// 这是超时阶梯里**最内层**的一环，见 `HookTimeouts`。
    private let timeout = HookTimeouts.userDecision

    private var orphanSweep: Task<Void, Never>?

    /// 审批日志的落盘位置。
    ///
    /// 这份数据的**唯一用途**就是"看一周再决定要不要把 dangerous 一档也拦上"——
    /// 只存在内存里的话 app 一重启就清零，这个功能等于不存在。
    public static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/approval-log.json")
    }

    /// nil = 不落盘。
    ///
    /// **必须可注入。** 把路径写死在类型里会让测试直接读写用户的真实日志：
    /// 测试之间互相污染是小事，往用户数据里写测试垃圾是真问题。
    private let logURL: URL?

    public init(logURL: URL? = defaultLogURL) {
        self.logURL = logURL
        log = Self.loadLog(from: logURL)
    }

    private static func loadLog(from url: URL?) -> [ApprovalLogEntry] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ApprovalLogEntry].self, from: data)
        else { return [] }
        return decoded
    }

    /// 每次追加都落盘。
    ///
    /// 频率极低（只有被拦截或被记录的高风险操作才走到这里），
    /// 而"崩溃/退出后丢掉最后几条"恰恰是最不能接受的 —— 用户想看的就是
    /// 刚才那次到底发生了什么。所以不做批量延迟写。
    private func persistLog() {
        guard let logURL else { return }
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: logURL, options: .atomic)
    }

    public var current: ApprovalRequest? { queue.first }

    // MARK: - 僵尸请求清理

    /// 定期清掉「发起方已经死了」的审批卡。
    ///
    /// 真实场景：Claude 被 Ctrl-C、会话被关、hook 进程超时被杀 —— 这些情况下
    /// hubctl 没了，但服务端仍然阻塞在等决策上，岛上那张卡会一直挂着。
    /// 用户要么被迫点一下一个**早已无人接收**的决策，要么它会一直挡住
    /// 后面真正需要处理的请求（队列是先进先出的）。
    ///
    /// 判据用 `HookEvent.clientPid` —— 这个字段本来就一路传过来了。
    /// 判 deny 而不是 allow：反正没人收，但万一对端还活着只是暂时不可见，
    /// 拒绝是可恢复的那一侧。
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
            // kill(pid, 0)：EPERM 说明进程存在但不属于我们，也算活着。
            guard kill(request.clientPid, 0) != 0, errno == ESRCH else { continue }
            resolve(
                id: request.id,
                decision: HookDecision(verdict: .deny, reason: "发起方已退出"),
                verdictLabel: "orphaned"
            )
        }
    }

    // MARK: - hook 侧入口

    /// 提交一次审批请求并等待结论。**会阻塞调用方直到有结果。**
    public func requestDecision(for request: ApprovalRequest) async -> HookDecision {
        queue.append(request)

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.timeout ?? 60))
            guard !Task.isCancelled else { return }
            await self?.resolve(
                id: request.id,
                decision: HookDecision(verdict: .deny, reason: "Vibe Foreman：60 秒未响应，已自动拒绝"),
                verdictLabel: "timeout"
            )
        }
        timeoutTasks[request.id] = task

        return await withCheckedContinuation { continuation in
            pending[request.id] = continuation
        }
    }

    // MARK: - UI 侧动作

    public func allow(_ request: ApprovalRequest) {
        resolve(
            id: request.id,
            decision: HookDecision(verdict: .allow),
            verdictLabel: "allow"
        )
    }

    public func deny(_ request: ApprovalRequest) {
        resolve(
            id: request.id,
            decision: HookDecision(verdict: .deny, reason: "用户在 Vibe Foreman 上拒绝了这次操作"),
            verdictLabel: "deny"
        )
    }

    /// 跳过：把当前这条挪到队尾，先处理别的。**不代表拒绝。**
    public func skip(_ request: ApprovalRequest) {
        guard queue.count > 1, let index = queue.firstIndex(where: { $0.id == request.id })
        else { return }
        let item = queue.remove(at: index)
        queue.append(item)
    }

    private func resolve(id: String, decision: HookDecision, verdictLabel: String) {
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil

        guard let continuation = pending.removeValue(forKey: id) else { return }
        let request = queue.first { $0.id == id }
        queue.removeAll { $0.id == id }
        continuation.resume(returning: decision)

        if let request {
            appendLog(request: request, verdict: verdictLabel, intercepted: true)
        }
    }

    /// 记一笔没有拦截的高风险操作（`dangerous` 档默认走这里）。
    public func recordWithoutIntercepting(
        projectName: String, toolName: String, command: String, risk: RiskLevel
    ) {
        log.insert(
            ApprovalLogEntry(
                id: UUID().uuidString, timestamp: Date(), projectName: projectName,
                toolName: toolName, command: command, risk: risk,
                verdict: "auto-allow", intercepted: false
            ),
            at: 0
        )
        trimLog()
    }

    /// 密钥泄漏闸拦下的一次调用。
    ///
    /// 和别的日志条目不同：这条**不是这里决策的** —— hubctl 在本地就拒了，
    /// 我们只是把它记下来。所以 verdict 写死 `guard-deny`，
    /// 不要拿它当"审批流程走过一遍"的证据。
    public func recordSecretGuardBlock(
        projectName: String, toolName: String, command: String, reason: String
    ) {
        log.insert(
            ApprovalLogEntry(
                id: UUID().uuidString, timestamp: Date(), projectName: projectName,
                toolName: toolName,
                // 命令本身可能什么都看不出来（比如 Write 只带文件名），
                // 把拦截理由拼上去，日志里一眼能看懂为什么被拦。
                command: command.isEmpty ? reason : "\(command)\n\(reason)",
                risk: .irreversible, verdict: "guard-deny", intercepted: true
            ),
            at: 0
        )
        trimLog()
    }

    private func appendLog(request: ApprovalRequest, verdict: String, intercepted: Bool) {
        log.insert(
            ApprovalLogEntry(
                id: request.id, timestamp: Date(), projectName: request.projectName,
                toolName: request.toolName, command: request.command, risk: request.risk,
                verdict: verdict, intercepted: intercepted
            ),
            at: 0
        )
        trimLog()
    }

    private func trimLog() {
        if log.count > 500 { log.removeLast(log.count - 500) }
        persistLog()
    }

    /// 清空审批日志（设置页用）。
    public func clearLog() {
        log = []
        persistLog()
    }
}
