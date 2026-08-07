import Foundation

/// 一条证据。
///
/// **刻意把「Claude 说的」和「Hub 跑出来的」做成不同的 case。**
///
/// 最自然的写法是 `evidence: [String]`，把两者都塞进去。但那样等于在数据结构
/// 层面就承认了"陈述和证明是一回事"—— 而这恰好是这个功能要解决的问题本身：
/// Claude 说"改了 x.swift、跑了测试"和它真的改了、真的跑了，是两件事。
///
/// 类型分开之后，"有几条是真证明"就成了一个编译期就说得清的问题（`isProof`），
/// UI 和报告都没法不小心把自述当成证明去展示。
public enum Evidence: Codable, Sendable, Equatable {
    /// Claude 自报的说辞。**不是证明**，只是待核验的线索。
    case claimed(String)
    /// Hub 自己跑 `git diff` 找到的真实改动。
    case diff(path: String, added: Int, removed: Int)
    /// Hub 自己执行命令的结果 —— 命令原文、退出码、输出尾部。
    case ran(command: String, exitCode: Int32, tail: String)

    /// 只有 Hub 亲手产出的才算证明。`.claimed` 永远是 false。
    ///
    /// 别在这里给 `.claimed` 开口子（比如"内容里带了文件路径就算"）——
    /// 那等于回到了"听它怎么说"。
    public var isProof: Bool {
        switch self {
        case .claimed: return false
        case .diff, .ran: return true
        }
    }

    /// 列表里的一行短标签。
    public var shortLabel: String {
        switch self {
        case .claimed:
            return "仅自述"
        case .diff(let path, let added, let removed):
            return "\((path as NSString).lastPathComponent) +\(added)/-\(removed)"
        case .ran(let command, let exitCode, _):
            return "\(command) → exit \(exitCode)"
        }
    }
}

/// 清单里的一个要点。
///
/// 「要点」不等于 Claude 的 TodoWrite 条目。后者是**施工步骤**（"重写轮播箭头"），
/// 前者是**用户要的功能**（"移动端能正常翻页"）。翻译发生在 Claude 脑子里，
/// 而遗漏就发生在那一步 —— 所以基线必须取自用户原话和用户批准过的计划。
public struct AcceptanceItem: Codable, Sendable, Identifiable, Equatable {

    /// 这条要点是从哪儿来的。UI 上做成徽章，让用户一眼看出"这是我说的"还是"机器推的"。
    public enum Origin: String, Codable, Sendable {
        /// 用户原话里拆出来的。
        case userPrompt
        /// 用户批准过的计划里拆出来的 —— 权威性最高。
        case plan
        /// 分析推导的隐含项（改了 A 就得同步 B）。用户没明说，所以要标出来。
        case inferred
        /// 用户手敲的。
        case manual
        /// **Claude 自己列的 todo。**
        ///
        /// 它不能当基线 —— 用户需求翻译成它的那一步就已经丢东西了，
        /// 这正是整个功能存在的理由。但把它整个排除也是错的：
        /// 「它自己列了 6 项，做完 3 项就说完事了」是遗漏最直接的证据，
        /// 而且这类承诺**不在用户的原话里，别处根本抓不到**。
        ///
        /// 所以它进清单，但单独标一档，和用户原话那些分开看。
        case assistantTask

        public var label: String {
            switch self {
            case .userPrompt: return "原话"
            case .plan: return "计划"
            case .inferred: return "推导"
            case .manual: return "手敲"
            case .assistantTask: return "AI 计划"
            }
        }

        /// 来自用户的（权威基线）还是来自 AI 的（待核对的自述）。
        public var isFromUser: Bool {
            switch self {
            case .userPrompt, .plan, .manual: return true
            case .inferred, .assistantTask: return false
            }
        }
    }

    public enum Status: String, Codable, Sendable {
        /// 没人碰过。
        case open
        /// Claude 自报做完了，还没复核。
        case claimed
        /// 旁路复核在真实 diff 里找到了对应改动。
        case confirmed
        /// 自报做完但 diff 里找不到 —— **这一档最值钱**，是整个功能存在的理由。
        case disputed
        /// 用户亲手勾的。终裁。
        case accepted
        /// 用户亲手划掉的（不做了 / 判断有误）。终裁。
        case dropped

        public var label: String {
            switch self {
            case .open: return "未验收"
            case .claimed: return "待复核"
            case .confirmed: return "已确认"
            case .disputed: return "存疑"
            case .accepted: return "已接受"
            case .dropped: return "已划掉"
            }
        }
    }

    public let id: String
    public var text: String
    /// 怎么算做到。尽量是可执行的命令（`swift test --filter Xxx`），
    /// 拆不出来就留自然语言 —— 那种只能人工看，报告里会如实标注。
    public var acceptance: String?
    public var origin: Origin
    public var status: Status
    public var evidence: [Evidence]
    /// 机器给的理由，或用户的批注。
    public var note: String?
    public let createdAt: Date
    public var updatedAt: Date
    public let sourceSessionId: String?
    /// 入库时的 HEAD。diff 回溯的起点 —— 没有它就没法回答"这条要点之后代码变了什么"。
    public var baselineCommit: String?

    public init(
        id: String = UUID().uuidString,
        text: String,
        acceptance: String? = nil,
        origin: Origin,
        status: Status = .open,
        evidence: [Evidence] = [],
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceSessionId: String? = nil,
        baselineCommit: String? = nil
    ) {
        self.id = id
        self.text = text
        self.acceptance = acceptance
        self.origin = origin
        self.status = status
        self.evidence = evidence
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceSessionId = sourceSessionId
        self.baselineCommit = baselineCommit
    }

    /// 手写解码，理由同 `AcceptanceLedger.init(from:)`：加字段不能让老数据全废。
    ///
    /// 只有 `id` / `text` / `origin` 是必须的 —— 少了它们这条要点就没有意义了。
    /// 其余一律给默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        origin = try container.decode(Origin.self, forKey: .origin)
        acceptance = try container.decodeIfPresent(String.self, forKey: .acceptance)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .open
        evidence = try container.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        sourceSessionId = try container.decodeIfPresent(String.self, forKey: .sourceSessionId)
        baselineCommit = try container.decodeIfPresent(String.self, forKey: .baselineCommit)
    }

    /// 用户终裁过的项。机器结论一律盖不掉 —— 见 `AcceptanceStore.applyAudit`。
    public var isSettledByUser: Bool { status == .accepted || status == .dropped }

    /// 这一项有没有**实测过的**证明。
    ///
    /// 用户的原话是"不是说说而已，包括实际功能证明"——那句要求就落在这个属性上。
    /// 汇报条的「已证」只数它为 true 的，否则那个数字又变成了转述 Claude 的话。
    public var hasProof: Bool { evidence.contains(where: \.isProof) }

    /// 还没有定论、需要用户关注的。
    public var needsAttention: Bool { status == .open || status == .disputed }

    /// Claude 最近一次的自报说辞。复核时拿它去定位该看哪几个文件 ——
    /// **只是线索，不是证据**，所以取的是 `.claimed` 那一档。
    public var latestClaim: String? {
        for case .claimed(let text) in evidence.reversed() { return text }
        return nil
    }
}

/// 用户说过的一句原话。
///
/// `UserPromptSubmit` 一到就零成本落这里，**不调模型**。拆解是异步消费这个缓冲的，
/// 因为拆解要花好几秒，而那个 hook 必须立刻返回。
/// 逐条解码的要点数组：坏的那条跳过，其余照常。
///
/// Swift 没有内置的"容错数组解码"，只能自己包一层。
private struct LossyItems: Decodable {
    let values: [AcceptanceItem]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var collected: [AcceptanceItem] = []
        while !container.isAtEnd {
            // 解不出来时也必须**消费掉**这一个元素，否则 isAtEnd 永远不为真 ——
            // 死循环。用一个空的占位类型把游标推过去。
            if let item = try? container.decode(AcceptanceItem.self) {
                collected.append(item)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        values = collected
    }

    /// 什么都不读，只为了让 unkeyedContainer 的游标前进一格。
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

public struct RawPrompt: Codable, Sendable, Equatable {
    public let text: String
    public let sessionId: String
    public let at: Date

    public init(text: String, sessionId: String, at: Date = Date()) {
        self.text = text
        self.sessionId = sessionId
        self.at = at
    }
}

/// 一个项目的验收清单。
///
/// **挂在项目上而不是会话上**：用户关了终端明天再开，要点不该跟着消失。
/// 会话只是"哪一轮动过它"，记在 `AcceptanceItem.sourceSessionId` 里。
public struct AcceptanceLedger: Codable, Sendable, Equatable {
    /// 展开后的项目绝对路径。主键。
    public var projectPath: String
    public var items: [AcceptanceItem]
    /// 还没拆解的用户原话缓冲。
    public var rawPrompts: [RawPrompt]
    /// 用户点过「允许执行」的命令原文。
    ///
    /// 按项目存，因为授权是有语境的：在自己的项目里跑 `swift test` 没问题，
    /// 不代表在别人 clone 来的仓库里也没问题。
    ///
    /// **它只是第三道闸。** 白名单和元字符检查在它之前，手工往这个数组里
    /// 塞一条危险命令绕不过前两道 —— 有测试守这一点。
    public var authorizedCommands: [String]
    public var updatedAt: Date

    public init(
        projectPath: String,
        items: [AcceptanceItem] = [],
        rawPrompts: [RawPrompt] = [],
        authorizedCommands: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.projectPath = projectPath
        self.items = items
        self.rawPrompts = rawPrompts
        self.authorizedCommands = authorizedCommands
        self.updatedAt = updatedAt
    }

    /// **手写解码，每个字段都 decodeIfPresent。**
    ///
    /// 合成的 Codable 对非可选字段要求必须存在 —— 给这个结构体加一个新字段，
    /// 所有已存在的清单文件当场全部解码失败。而 `AcceptanceStore` 的读取是
    /// `try?` 静默吞错误的，于是下一次写入会从空清单开始，**把用户攒的东西
    /// 整个覆盖掉**。
    ///
    /// 这不是假想：加 `authorizedCommands` 那次就这么丢了一份 13 条的清单，
    /// 而且当时还有两个项目的文件正等着被同样地清空。
    ///
    /// 清单是长期累积的数据，向后兼容不是可选项。以后加字段照着这里写。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        // 逐条解，坏的跳过。
        //
        // 直接 `decode([AcceptanceItem].self)` 的话，**一条坏了整份清单就报废** ——
        // 而报废的后果是这个项目的几十条要点全部读不出来。同 TaskStateReader
        // 的处理：清单是边跑边写的，撞上半条数据是正常情况，不是异常。
        items = try container.decodeIfPresent(LossyItems.self, forKey: .items)?.values ?? []
        rawPrompts = try container.decodeIfPresent([RawPrompt].self, forKey: .rawPrompts) ?? []
        authorizedCommands = try container.decodeIfPresent(
            [String].self, forKey: .authorizedCommands
        ) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public var isEmpty: Bool { items.isEmpty && rawPrompts.isEmpty }

    // MARK: - 汇报级统计
    //
    // app 窗口窄，塞不下逐条证据，所以列表上方那一行汇报条是主要的信息载体。
    // 这几个计数就是那一行。

    public var disputedCount: Int { items.filter { $0.status == .disputed }.count }
    public var openCount: Int { items.filter { $0.status == .open }.count }
    public var claimedCount: Int { items.filter { $0.status == .claimed }.count }

    /// 有实测证明的条数。
    ///
    /// **只数 `hasProof`，不数 `.confirmed`。** 一条要点可以因为 diff 里有痕迹而
    /// 被判 confirmed，但那仍然只是"代码动过"，不是"功能能用"。这个数字要能
    /// 回答的是后者。
    public var provenCount: Int { items.filter(\.hasProof).count }

    /// 列表上方的分段切换。
    ///
    /// 六种状态平铺成六个分组时，页面要滚很久才能看到「疑似未做」——
    /// 而那恰恰是唯一真正需要你动手的一档。切成三段之后，最要紧的那段
    /// 是一次点击就能到的。
    public enum Lane: String, CaseIterable, Sendable, Identifiable {
        case pending = "待验收"
        case disputed = "疑似未做"
        case done = "已验收"

        public var id: String { rawValue }

        public func contains(_ status: AcceptanceItem.Status) -> Bool {
            switch self {
            case .pending: return status == .open || status == .claimed
            case .disputed: return status == .disputed
            // 已划掉的归到「已验收」而不是单开一段：它同样是"有定论了、不用再管"，
            // 单开一段只会让最需要注意的那一档更难找。
            case .done: return status == .confirmed || status == .accepted || status == .dropped
            }
        }
    }

    public func items(in lane: Lane) -> [AcceptanceItem] {
        items.filter { lane.contains($0.status) }
    }

    public func count(in lane: Lane) -> Int {
        items.reduce(0) { lane.contains($1.status) ? $0 + 1 : $0 }
    }

    /// 一句话汇报。UI 和导出报告共用，避免两处各写一份然后漂移。
    public var headline: String {
        var parts: [String] = []
        if disputedCount > 0 { parts.append("存疑 \(disputedCount)") }
        if openCount > 0 { parts.append("未验收 \(openCount)") }
        if claimedCount > 0 { parts.append("待复核 \(claimedCount)") }
        parts.append("已证 \(provenCount)/\(items.count)")
        return parts.joined(separator: " · ")
    }
}
