import Foundation
import HubCore

/// 一个会话为什么卡在那儿没人管。
///
/// 五类都来自用户实拍的真实场景，不是设想出来的分类。
public enum StallReason: Equatable, Sendable {
    /// 这一轮死在半路上（`API Error: Connection closed mid-response`）。
    /// 最贵的一类：跑了一小时、任务只做一半，用户可能几小时后才发现。
    case interrupted(String)

    /// AI 在问你一个问题，等一句回答（"需要我帮你把这两个提交推送到 live 吗？"）。
    /// 这类可以在岛上直接答，不必跳终端。
    case askedQuestion(String)

    /// 等授权或等选择（plan 模式的 `Would you like to proceed?`）。
    case awaitingDecision(String?)

    /// 做完一个阶段停下了，清单里还有没做完的。
    case unfinishedTasks(pending: Int, inProgress: Int, next: String?)

    /// 安静地干完了，等你验收。无错、无未完成任务、也没提问。
    case finishedAwaitingReview(summary: String?, workedFor: TimeInterval)

    /// 排序即处理优先级。
    ///
    /// 断线是异常，永远排最前；"AI 在等你一句话"比"你该去验收"更堵着流程，
    /// 因为前者不回答那边就一直停着。
    public var priority: Int {
        switch self {
        case .interrupted: return 0
        case .askedQuestion: return 1
        case .awaitingDecision: return 2
        case .unfinishedTasks: return 3
        case .finishedAwaitingReview: return 4
        }
    }

    /// 岛上用的原因图标。
    public var symbol: String {
        switch self {
        case .interrupted: return "⚡"
        case .askedQuestion: return "❓"
        case .awaitingDecision: return "⚠"
        case .unfinishedTasks: return "▸"
        case .finishedAwaitingReview: return "✓"
        }
    }

    /// 折叠态跑马灯用的短语。下唇只有 14pt 高、字最多 9pt，**必须极短**。
    public var shortLabel: String {
        switch self {
        case .interrupted: return "断线了"
        case .askedQuestion: return "在问你"
        case .awaitingDecision: return "等授权"
        case .unfinishedTasks: return "有后续"
        case .finishedAwaitingReview: return "待验收"
        }
    }
}

/// 提醒的力度。
public enum StallGrade: Equatable, Sendable {
    /// 走完整升级阶梯，会主动膨胀打断用户。
    case high
    /// 只上跑马灯和下唇染色，**不主动闯入**。
    case low
}

public struct StallFinding: Equatable, Sendable {
    public let sessionId: String
    public let reason: StallReason
    public let grade: StallGrade
    /// 从什么时候开始卡着的。升级阶梯按这个计时。
    public let since: Date

    public init(sessionId: String, reason: StallReason, grade: StallGrade, since: Date) {
        self.sessionId = sessionId
        self.reason = reason
        self.grade = grade
        self.since = since
    }
}

/// 各类场景"静默多久才算卡住"。
///
/// 这些值直接决定打扰频率，必须能在设置页调 —— 写死的话不同工作节奏的人
/// 一定会有一半觉得太吵、另一半觉得太迟钝。
public struct StallThresholds: Equatable, Sendable {
    /// 断线**立即**报。异常没有"正常等待"一说。
    public var interrupted: TimeInterval = 0
    public var askedQuestion: TimeInterval = 90
    public var awaitingDecision: TimeInterval = 90
    public var unfinishedTasks: TimeInterval = 5 * 60
    public var finishedAwaitingReview: TimeInterval = 3 * 60

    /// 干活超过这个时长才算"值得打断你去验收"的活。
    ///
    /// 同时跑七八个会话时，几十秒的小活也主动弹岛会立刻变成必须关掉的骚扰。
    public var reviewWorthyWork: TimeInterval = 5 * 60

    public init() {}
}

/// AI 那层的产出。都是"把事情说清楚"，不含"要不要提醒"的判断 ——
/// 后者由确定性规则决定，AI 出错只会让文案变糙，不会漏报或误报。
public struct StallSummary: Equatable, Sendable {
    public let summary: String?
    public let isQuestion: Bool
    public let question: String?
    public let options: [String]
    public let nextAction: String?

    public init(
        summary: String? = nil, isQuestion: Bool = false, question: String? = nil,
        options: [String] = [], nextAction: String? = nil
    ) {
        self.summary = summary
        self.isQuestion = isQuestion
        self.question = question
        self.options = options
        self.nextAction = nextAction
    }
}

/// 判定一个会话是不是卡住了，以及为什么。
///
/// **纯函数**，不碰磁盘也不碰时钟 —— 所有输入都由调用方备好、`now` 显式传入。
/// 这样升级阶梯的时序才能在测试里注入可控时钟，不用真的等 20 分钟。
public struct StallDetector: Sendable {

    public var thresholds: StallThresholds

    public init(thresholds: StallThresholds = StallThresholds()) {
        self.thresholds = thresholds
    }

    public struct Input: Sendable {
        public let session: AgentSession
        public let tail: TranscriptTail?
        public let tasks: TaskSnapshot?
        /// 这个会话上一轮 `busy` 持续了多久。分级的依据。
        ///
        /// `nil` 表示不知道（app 刚起、还没观测到一次完整的 busy→idle）。
        /// 不知道时**按高优处理** —— 漏提醒的代价比多提醒一次大。
        public let busyDuration: TimeInterval?
        /// AI 那层的产出，可能没有（未启用 / 还没轮到 / 调用失败）。
        public let ai: StallSummary?

        public init(
            session: AgentSession,
            tail: TranscriptTail? = nil,
            tasks: TaskSnapshot? = nil,
            busyDuration: TimeInterval? = nil,
            ai: StallSummary? = nil
        ) {
            self.session = session
            self.tail = tail
            self.tasks = tasks
            self.busyDuration = busyDuration
            self.ai = ai
        }
    }

    public func evaluate(_ input: Input, now: Date) -> StallFinding? {
        let session = input.session

        // 正在干活的会话不存在"卡住"。shell 也算在干活。
        guard session.status == .idle || session.status == .waiting else { return nil }

        // 静默起点：状态最后一次变化的时刻。这正是"它在这个状态里待了多久"。
        let since = session.statusUpdatedAt ?? session.updatedAt ?? now
        let silent = now.timeIntervalSince(since)
        guard silent >= 0 else { return nil }

        guard let reason = classify(input, silentFor: silent) else { return nil }
        return StallFinding(
            sessionId: session.sessionId,
            reason: reason,
            grade: grade(for: reason, busyDuration: input.busyDuration),
            since: since
        )
    }

    /// 按优先级从高到低逐条试，第一条命中且过了自己的阈值就是结论。
    private func classify(_ input: Input, silentFor silent: TimeInterval) -> StallReason? {
        // ① 断线。确定性判据，不用猜，也不用等。
        if input.tail?.endedWithApiError == true, silent >= thresholds.interrupted {
            let text = input.tail?.lastAssistantText ?? "连接中断，这一轮没跑完"
            return .interrupted(text)
        }

        // ② AI 在提问。
        if silent >= thresholds.askedQuestion, let question = detectQuestion(input) {
            return .askedQuestion(question)
        }

        // ③ 等授权 / 等选择。Claude 自己写的 waiting 状态，权威。
        if input.session.status == .waiting, silent >= thresholds.awaitingDecision {
            return .awaitingDecision(input.session.waitingFor)
        }

        // ④ 清单里还有没做完的。
        if let tasks = input.tasks, tasks.unfinished > 0,
           silent >= thresholds.unfinishedTasks {
            return .unfinishedTasks(
                pending: tasks.pending, inProgress: tasks.inProgress, next: tasks.nextSubject
            )
        }

        // ⑤ 兜底：安静地干完了，等你验收。
        //
        // 用户明确要求过这一类也要提醒（"完成好了 应该提醒验收或者继续
        // 但是现在都没有提示"），所以这里**不是**可选项，是默认结论。
        // 噪音由分级和升级阶梯来控制，不靠少报。
        if silent >= thresholds.finishedAwaitingReview {
            return .finishedAwaitingReview(
                summary: input.ai?.summary ?? input.tail?.lastAssistantText.map { Self.condense($0) },
                workedFor: input.busyDuration ?? 0
            )
        }

        return nil
    }

    /// AI 说是提问就以 AI 为准；AI 不可用时退到一条**很窄**的启发式。
    ///
    /// 启发式只看**最后一个非空行**是不是以问号结尾，不扫全文 ——
    /// 正文中间的反问句非常常见（"这样对吗？其实不对，因为…"），
    /// 扫全文必然误判。实测两个真实样本：
    ///   "…需要我帮你把这两个提交精准推送到 live 吗？"  → 命中
    ///   "…前后端服务都已重启在跑。"                    → 不命中
    private func detectQuestion(_ input: Input) -> String? {
        if let ai = input.ai {
            guard ai.isQuestion else { return nil }
            return ai.question ?? ai.summary
        }
        guard let text = input.tail?.lastAssistantText else { return nil }
        guard let last = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty })
        else { return nil }

        guard last.hasSuffix("？") || last.hasSuffix("?") else { return nil }
        return Self.condense(last)
    }

    /// 分级：只有"干了没多久就安静收工"才降级。
    /// 其余四类都堵着流程，一律高优。
    private func grade(for reason: StallReason, busyDuration: TimeInterval?) -> StallGrade {
        guard case .finishedAwaitingReview = reason else { return .high }
        // 不知道干了多久时按高优 —— 漏提醒比多提醒一次代价大。
        guard let worked = busyDuration else { return .high }
        return worked >= thresholds.reviewWorthyWork ? .high : .low
    }

    /// 压成一行短文本。岛上放不下长句，通知正文也只有一行。
    public static func condense(_ text: String, limit: Int = 60) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit - 1)) + "…"
    }
}
