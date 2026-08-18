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
        /// 用户敲了回车提交一句话。
        ///
        /// **只采集，不干预** —— 这个 hook 的 stdout 会被 Claude 当成附加 context
        /// 注入进对话，所以它这条链路一个字都不能往 stdout 打（配 `async: true` 双保险）。
        ///
        /// 它是验收清单的两个作用：把用户原话存进清单缓冲；给 Stop 的拦截「上膛」。
        /// 后者是防死循环的结构性保证 —— 只有用户说话能上膛，Claude 没有任何路径
        /// 能给自己上膛，详见 `AcceptanceStore` 里那一段。
        case userPromptSubmit
        /// 会话开始。Hub 借它做项目配置检查，也是「通道健康度」的起点。
        case sessionStart
        /// 工具调用**之后**。
        ///
        /// 这一条对验收清单的价值最大：Write / Edit 之后 Hub 能**第一手**知道
        /// 哪个文件被改了，不用回头问 Claude "你改了什么"。
        /// 转述那一步正是失真发生的地方。
        case postToolUse
        /// 子 agent 收工。
        case subagentStop
        /// 上下文即将被压缩。
        ///
        /// 压缩正是"遗忘"最集中发生的时刻 —— Claude 记不住的东西，
        /// Hub 的清单记得住。
        case preCompact

        /// 这类事件的发起方在等一个决策，服务端必须回写。
        ///
        /// **hubctl 和 HubSocketServer 必须都用这一个属性判断，别各写各的 `if`。**
        ///
        /// 这条来自一次真实事故：把 Stop 改成阻塞式时只动了 hubctl（让它等应答），
        /// 服务端那边的 `guard kind == .preToolUse` 原封不动 —— 于是 hubctl 等到的
        /// 永远是连接关闭，拦截**一次都没生效过**，而且不报错、不超时、
        /// 表现得和"清单里没有待办"一模一样。查了三轮才找到。
        ///
        /// 两边共用一个判断之后，这种分歧在结构上就不成立了。
        public var expectsDecision: Bool {
            switch self {
            case .preToolUse, .stop: return true
            case .notification, .sessionEnd, .userPromptSubmit,
                 .sessionStart, .postToolUse, .subagentStop, .preCompact: return false
            }
        }
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
    /// Claude 是不是**已经**因为 Stop hook 而在续跑了。
    ///
    /// 用来避免"拦了又拦"。但**绝不能只靠它** —— 这个字段在本机没验证过，
    /// 不同 CLI 版本给不给都不确定。真正的保证是 Hub 侧的上膛机制。
    /// 它在这里只是第二道。
    public let stopHookActive: Bool?

    // MARK: userPromptSubmit

    /// 用户刚提交的那句原话。验收清单的基线就取自它。
    public let promptText: String?

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

    /// hubctl 本地那道密钥泄漏闸的判定结果。非 nil = **这次已经被本地拦下了**。
    ///
    /// 事件照发，是为了让它出现在审批日志里 —— 一道看不见的闸，
    /// 用户第一次被拦时只会觉得 Claude 抽风。
    public let guardFinding: String?

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
        stopHookActive: Bool? = nil,
        promptText: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        toolName: String? = nil,
        toolSummary: String? = nil,
        toolUseId: String? = nil,
        toolInputJSON: String? = nil,
        guardFinding: String? = nil,
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
        self.stopHookActive = stopHookActive
        self.promptText = promptText
        self.notificationType = notificationType
        self.message = message
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.toolUseId = toolUseId
        self.toolInputJSON = toolInputJSON
        self.guardFinding = guardFinding
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
                "permissionDecisionReason": reason ?? "被 Vibe Foreman 拦截",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stop hook 应答的 stdout 内容。
    ///
    /// `{"decision":"block","reason":...}` 会让 Claude **不停下来**，
    /// 并把 reason 当成新的输入继续跑一轮 —— 验收清单就是靠这个塞回去的。
    ///
    /// nil = 什么都不输出 = 正常收工。**这是绝大多数情况**，也是所有异常
    /// 情况的落点：Hub 没运行、桥接超时、清单为空、没上膛，全都走这里。
    ///
    /// 注意和 `hookOutputJSON()` 的格式**完全不同**（那个是
    /// hookSpecificOutput + permissionDecision），别想着合并成一个。
    public func stopOutputJSON() -> String? {
        guard verdict == .deny, let reason, !reason.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["decision": "block", "reason": reason]
        ) else { return nil }
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
