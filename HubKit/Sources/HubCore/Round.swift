import Foundation

/// 观察者分析对某一条参考要点在**这一轮**里的结论。
public struct RoundVerdict: Codable, Sendable, Equatable {
    public let itemId: String
    public let confirmed: Bool
    public let note: String?
    public let evidence: [Evidence]

    public init(itemId: String, confirmed: Bool, note: String? = nil, evidence: [Evidence] = []) {
        self.itemId = itemId
        self.confirmed = confirmed
        self.note = note
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey { case itemId, confirmed, note, evidence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decode(String.self, forKey: .itemId)
        confirmed = try container.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        note = try container.decodeIfPresent(String.self, forKey: .note)
        evidence = try container.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
    }
}

/// 一「轮」开发：用户敲回车（UserPromptSubmit）到 Claude 收工（Stop）。
///
/// hub 是**观察者**：轮次记录是看到什么记什么，不打扰会话。
/// 这份数据是时间轴 UI 的唯一来源 —— 「本轮说了要做什么、实际做没做到」
/// 以前只存在于一闪而过的通知正文里，现在落盘可回看。
public struct RoundRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sessionId: String
    public let projectPath: String
    /// 首条 prompt 压成一行、截 120 字。后续 prompt 只计数不追加 ——
    /// 时间轴一行放不下两句话，细节在会话记录里本来就有。
    public var promptSummary: String
    /// 一轮里用户说了几句（Stop 前多次 UserPromptSubmit 并进同一轮）。
    public var promptCount: Int
    /// 观察者分析的产出：「说了什么 vs 实际改了什么」。纯问答轮为 nil。
    public var recap: String?
    public var verdicts: [RoundVerdict]
    /// diff 一行摘要（"3 个文件 +120/-45"）。收口时不 fork git，由分析任务补写。
    public var diffStat: String?
    public var touchedFileCount: Int
    /// 门槛判定结果。true = 有实改（才值得调模型分析），UI 用它区分节点样式。
    public var hadRealChanges: Bool
    /// 开轮时的 HEAD。分析的 diff 从这儿起算。
    public var baselineCommit: String?
    public let startedAt: Date
    /// nil = 进行中（或 app 重启遗留，loadAll 会补收口）。
    public var endedAt: Date?
    /// Claude 最终回复的压缩版（≤200 字）。分析失败/纯问答轮的兜底展示。
    public var assistantSummary: String?

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        projectPath: String,
        promptSummary: String,
        promptCount: Int = 1,
        recap: String? = nil,
        verdicts: [RoundVerdict] = [],
        diffStat: String? = nil,
        touchedFileCount: Int = 0,
        hadRealChanges: Bool = false,
        baselineCommit: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        assistantSummary: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.promptSummary = promptSummary
        self.promptCount = promptCount
        self.recap = recap
        self.verdicts = verdicts
        self.diffStat = diffStat
        self.touchedFileCount = touchedFileCount
        self.hadRealChanges = hadRealChanges
        self.baselineCommit = baselineCommit
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.assistantSummary = assistantSummary
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionId, projectPath, promptSummary, promptCount, recap, verdicts
        case diffStat, touchedFileCount, hadRealChanges, baselineCommit
        case startedAt, endedAt, assistantSummary
    }

    /// 手写解码：除四个身份字段外全部 decodeIfPresent ——
    /// 这份数据要长期累积，加字段不能让老文件解码失败
    /// （AcceptanceLedger 因为这个真丢过 13 条，同一个错不犯第二次）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        promptSummary = try container.decodeIfPresent(String.self, forKey: .promptSummary) ?? ""
        promptCount = try container.decodeIfPresent(Int.self, forKey: .promptCount) ?? 1
        recap = try container.decodeIfPresent(String.self, forKey: .recap)
        verdicts = try container.decodeIfPresent([RoundVerdict].self, forKey: .verdicts) ?? []
        diffStat = try container.decodeIfPresent(String.self, forKey: .diffStat)
        touchedFileCount = try container.decodeIfPresent(Int.self, forKey: .touchedFileCount) ?? 0
        hadRealChanges = try container.decodeIfPresent(Bool.self, forKey: .hadRealChanges) ?? false
        baselineCommit = try container.decodeIfPresent(String.self, forKey: .baselineCommit)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        assistantSummary = try container.decodeIfPresent(String.self, forKey: .assistantSummary)
    }

    /// prompt 压成时间轴一行：换行并成空格、截 120 字（加省略号）。
    public static func summarize(prompt: String) -> String {
        let flat = prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flat.count > 120 else { return flat }
        return String(flat.prefix(120)) + "…"
    }
}

/// 一个项目的轮次日志。新的在前。
public struct RoundLog: Codable, Sendable, Equatable {
    public var projectPath: String
    public var rounds: [RoundRecord]
    public var updatedAt: Date

    public init(projectPath: String, rounds: [RoundRecord] = [], updatedAt: Date = Date()) {
        self.projectPath = projectPath
        self.rounds = rounds
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case projectPath, rounds, updatedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        // 逐条容错：一条坏的不连累整份（同 AcceptanceLedger 的 LossyItems）。
        rounds = (try? container.decode(LossyRounds.self, forKey: .rounds))?.values ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// 逐条解码的轮次数组：坏的那条跳过，其余照常。
private struct LossyRounds: Decodable {
    let values: [RoundRecord]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var collected: [RoundRecord] = []
        while !container.isAtEnd {
            if let round = try? container.decode(RoundRecord.self) {
                collected.append(round)
            } else {
                // 解不出来也必须消费掉这个元素，否则 isAtEnd 永远不为真。
                _ = try? container.decode(Skip.self)
            }
        }
        values = collected
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
