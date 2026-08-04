import Foundation

/// Claude Code hook 送过来的事件。
///
/// 字段直接对应 hook 的 stdin JSON（已查证官方文档）。旧实现的 bash hook
/// **完全没读 stdin**，把 `session_id` / `cwd` / `last_assistant_message`
/// 全丢了，只能靠 `tmux display-message -p '#W'` 猜项目名 —— 那还漏了
/// `-t "$TMUX_PANE"`，拿到的是当前 active 窗口而不是自己所在窗口。
/// 用户切个 tab，通知就挂到别的项目上了。
public struct HookEvent: Codable, Sendable {

    public enum Kind: String, Codable, Sendable {
        /// Claude 完成一轮回复。
        case stop
        /// 通知类事件（需要授权、空闲提醒、子 agent 完成等）。
        case notification
        /// 工具调用前。**阻塞式** —— hubctl 会等岛上的决策。
        case preToolUse
        /// 会话结束，用于即时清理 UI。
        case sessionEnd
    }

    public let kind: Kind
    /// 请求唯一 id。审批的应答靠它对上号。
    public let requestId: String

    // MARK: Claude 提供的通用字段

    public let sessionId: String
    public let cwd: String
    public let transcriptPath: String?
    public let permissionMode: String?

    // MARK: stop

    /// Claude 这一轮的最终回复文本。
    /// 通知正文直接用它，替掉旧实现那 5 条随机中文文案（信息量为零）。
    public let lastAssistantMessage: String?
    public let stopReason: String?

    // MARK: notification

    /// `permission_prompt` / `idle_prompt` / `agent_completed` 等。
    public let notificationType: String?
    public let message: String?

    // MARK: preToolUse

    public let toolName: String?
    /// 工具参数里最能代表"这次要干什么"的那个值。
    /// Bash 取 command，Write/Edit 取 file_path，WebFetch 取 url。
    public let toolSummary: String?
    public let toolUseId: String?
    /// 完整 tool_input 的 JSON 原文。只有交互类工具（AskUserQuestion /
    /// ExitPlanMode）才带 —— 岛上要把真实的问题和选项渲染出来，
    /// 一行 summary 不够用。其余工具仍然只传 toolSummary，别撑爆行协议。
    public let toolInputJSON: String?

    // MARK: hubctl 补充的环境信息

    /// `$TMUX_PANE`。在 tmux 里跑时能直接定位 pane，不用猜。
    public let tmuxPane: String?
    /// hook 进程自己的 PID，用于反查是哪个 claude 进程。
    public let clientPid: Int32?

    public init(
        kind: Kind,
        requestId: String,
        sessionId: String,
        cwd: String,
        transcriptPath: String? = nil,
        permissionMode: String? = nil,
        lastAssistantMessage: String? = nil,
        stopReason: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        toolName: String? = nil,
        toolSummary: String? = nil,
        toolUseId: String? = nil,
        toolInputJSON: String? = nil,
        tmuxPane: String? = nil,
        clientPid: Int32? = nil
    ) {
        self.kind = kind
        self.requestId = requestId
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.permissionMode = permissionMode
        self.lastAssistantMessage = lastAssistantMessage
        self.stopReason = stopReason
        self.notificationType = notificationType
        self.message = message
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.toolUseId = toolUseId
        self.toolInputJSON = toolInputJSON
        self.tmuxPane = tmuxPane
        self.clientPid = clientPid
    }

    /// 项目名兜底。真正的项目名由 projects.yaml 反查 cwd 得到。
    public var fallbackProjectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// 审批结论。只有 `preToolUse` 会收到应答。
public struct HookDecision: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case allow
        case deny
        /// 交回 Claude 自己的权限流程。
        case ask
    }

    public let verdict: Verdict
    public let reason: String?

    /// true = 要求 hubctl **显式输出** `permissionDecision: "allow"`。
    ///
    /// 现状的 allow 是"什么都不输出"= 交回 Claude 自己的权限流程（终端里
    /// 该弹的确认框照弹）。但岛上「批准计划」需要的是真放行 —— 只有显式
    /// 输出 allow，ExitPlanMode 才会跳过终端确认直接执行。
    /// nil / false 维持现状语义。
    public let explicitAllow: Bool?

    public init(verdict: Verdict, reason: String? = nil, explicitAllow: Bool? = nil) {
        self.verdict = verdict
        self.reason = reason
        self.explicitAllow = explicitAllow
    }

    /// 放行。Hub 没运行、超时以外的异常、非高风险操作都走这个。
    public static let allow = HookDecision(verdict: .allow)

    /// PreToolUse 应答的 stdout 内容（已查证官方文档的格式）。
    /// nil = 什么都不输出 = 交回 Claude 正常权限流程。
    /// 放在这里而不是 hubctl 里，是为了让"什么情况输出什么"可测。
    public func hookOutputJSON() -> String? {
        if verdict == .allow, explicitAllow != true { return nil }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": verdict.rawValue,
                "permissionDecisionReason": reason ?? "被 Claude Hub 拦截",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// socket 路径。
public enum HubSocket {
    public static var path: String {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hub.sock").path
    }

    /// Unix domain socket 的路径长度上限（`sun_path` 是 104 字节）。
    /// 超了 bind 会静默失败，所以建立前必须检查。
    public static let maxPathLength = 103
}
