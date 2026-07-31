import Foundation

/// 会话状态。取值来自 Claude Code 自己写的 `~/.claude/sessions/<PID>.json`，
/// 不是我们推断出来的 —— 这是权威来源。
///
/// 排序即 UI 优先级：waiting 永远排最前（它是唯一需要用户立刻行动的状态）。
public enum SessionStatus: String, Codable, Sendable, CaseIterable, Comparable {
    /// 等用户输入或授权。伴随 `waitingFor` 说明原因。
    case waiting
    /// 正在干活（模型推理 / 工具调用）。
    case busy
    /// 正在跑 shell 命令。
    case shell
    /// 空闲。
    case idle
    /// 未来 Claude Code 新增的取值。保留原字符串，不丢信息。
    case unknown

    /// 未知状态排在最后，避免新版本 Claude 引入新取值时抢占 waiting 的位置。
    private var rank: Int {
        switch self {
        case .waiting: return 0
        case .busy: return 1
        case .shell: return 2
        case .idle: return 3
        case .unknown: return 4
        }
    }

    public static func < (lhs: SessionStatus, rhs: SessionStatus) -> Bool {
        lhs.rank < rhs.rank
    }

    /// 是否算「活跃」——影响像素小人时钟频率与轮询节奏。
    public var isActive: Bool {
        self == .busy || self == .shell || self == .waiting
    }

    /// 是否**正在干活**。
    ///
    /// 和 `isActive` 的区别在 `waiting`：那是停下来等人，不是在干活。
    /// 用它来观测"这一轮活干了多久"，把 waiting 算进去会让时长虚高 ——
    /// 一个等了两小时授权的会话会被记成"干了两小时"，从而误判成高优。
    public var isWorking: Bool {
        self == .busy || self == .shell
    }
}

/// 会话类型。`bg` 是通过后台任务派发的，带 `jobId`。
public enum SessionKind: String, Codable, Sendable {
    case interactive
    case bg
    case unknown
}

/// 一个正在运行的 AI agent 会话。
///
/// 身份键是 `sessionId`（UUID）而**不是** `pid`：`--resume` 之后进程会换 PID，
/// 但 sessionId 不变。用 PID 做身份会让 UI 在 resume 时闪一下（旧条目消失、新条目出现）。
public struct AgentSession: Identifiable, Hashable, Sendable {
    /// Claude Code 的 session UUID。整个系统的主键。
    public let sessionId: String
    /// 当前进程 PID。会随 resume 变化，只用于定位进程树，不做身份。
    public let pid: pid_t
    /// 会话工作目录。
    public let cwd: String
    /// Claude 自己派生的会话名，如 `storefront-a-c3`、`o3-ui-memory-idempotent-fixes`。
    public let name: String?
    public let status: SessionStatus
    /// 原始 status 字符串。`status == .unknown` 时用它排查。
    public let rawStatus: String
    public let kind: SessionKind
    /// `waiting` 时的原因，如 `"input needed"`。
    public let waitingFor: String?
    public let jobId: String?
    /// Claude Code 版本号。注意：这也是 claude 的进程名。
    public let version: String?
    public let startedAt: Date?
    /// 状态最后一次变化的时刻。waiting 组内排序用它（等得最久的排最前）。
    public let statusUpdatedAt: Date?
    public let updatedAt: Date?

    public var id: String { sessionId }

    public init(
        sessionId: String,
        pid: pid_t,
        cwd: String,
        name: String? = nil,
        status: SessionStatus,
        rawStatus: String,
        kind: SessionKind,
        waitingFor: String? = nil,
        jobId: String? = nil,
        version: String? = nil,
        startedAt: Date? = nil,
        statusUpdatedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.pid = pid
        self.cwd = cwd
        self.name = name
        self.status = status
        self.rawStatus = rawStatus
        self.kind = kind
        self.waitingFor = waitingFor
        self.jobId = jobId
        self.version = version
        self.startedAt = startedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.updatedAt = updatedAt
    }

    /// 从 cwd 推出的项目名兜底值。真正的项目名由 projects.yaml 反查，查不到才用这个。
    public var fallbackProjectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

// MARK: - 解析

extension AgentSession {
    /// `~/.claude/sessions/<PID>.json` 的线格式。
    ///
    /// 全部字段设为可选 —— 这个文件由 Claude Code 写，schema 可能随版本变化，
    /// 少一个字段不该让整个探测失败。只有 `pid` / `sessionId` / `cwd` 是硬要求。
    struct Wire: Decodable {
        let pid: Int32?
        let sessionId: String?
        let cwd: String?
        let name: String?
        let status: String?
        let kind: String?
        let waitingFor: String?
        let jobId: String?
        let version: String?
        let startedAt: Double?       // 毫秒时间戳
        let statusUpdatedAt: Double?
        let updatedAt: Double?
    }

    /// 解析单个 sessions/*.json。字段缺失或格式不符时返回 nil，由调用方跳过。
    public static func decode(from data: Data) -> AgentSession? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let pid = wire.pid,
              let sessionId = wire.sessionId, !sessionId.isEmpty,
              let cwd = wire.cwd
        else { return nil }

        let raw = wire.status ?? ""
        return AgentSession(
            sessionId: sessionId,
            pid: pid,
            cwd: cwd,
            name: wire.name,
            status: SessionStatus(rawValue: raw) ?? .unknown,
            rawStatus: raw,
            kind: wire.kind.flatMap(SessionKind.init(rawValue:)) ?? .unknown,
            waitingFor: wire.waitingFor,
            jobId: wire.jobId,
            version: wire.version,
            startedAt: Self.date(fromMillis: wire.startedAt),
            statusUpdatedAt: Self.date(fromMillis: wire.statusUpdatedAt),
            updatedAt: Self.date(fromMillis: wire.updatedAt)
        )
    }

    private static func date(fromMillis millis: Double?) -> Date? {
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
