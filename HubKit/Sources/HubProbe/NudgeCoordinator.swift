import Foundation

/// 一次要发出的提醒。
public struct Nudge: Equatable, Sendable {
    /// 这一次要一起展示的会话。**多个卡住的会话合并成一次**，不排队弹 N 次。
    public let findings: [StallFinding]
    /// 第几轮（0 起）。用来决定要不要出声、要不要重发通知。
    public let round: Int
    /// 出声。第一轮静默，从第二轮开始出声 —— 头一次就叫会显得过于急躁。
    public let sound: Bool
    /// 重发系统通知（用新的 identifier）。
    ///
    /// 同 identifier 的通知在通知中心里是**静默替换**，不会重新弹横幅，
    /// 所以升级到这一档时必须换 id，否则用户根本看不到"又催了一次"。
    public let renotify: Bool

    public init(findings: [StallFinding], round: Int, sound: Bool, renotify: Bool) {
        self.findings = findings
        self.round = round
        self.sound = sound
        self.renotify = renotify
    }
}

/// 提醒的升级节奏。
public struct NudgeLadder: Equatable, Sendable {
    /// 每一轮距离"开始卡住"的时间。递增而不是固定间隔 ——
    /// 固定间隔在用户"知道但暂时不想处理"时会变成必须关掉的骚扰。
    public var steps: [TimeInterval] = [0, 3 * 60, 8 * 60, 20 * 60]
    /// 走完 `steps` 之后的固定间隔。
    public var repeatInterval: TimeInterval = 20 * 60

    /// **主动闯入的次数上限。**
    ///
    /// 这条是拿真实数据逼出来的：本机有个会话已经 idle 46 小时，
    /// 按"每 20 分钟一轮、不再加码"会主动弹 138 次。
    /// 那不是提醒，那是必须被关掉的东西。
    public var maxActiveRounds = 5

    /// 因**原因变化**重置阶梯的次数上限。
    ///
    /// 原因变了重新计时是对的（"断线了"和"待验收"是两件事，不该沿用旧轮次），
    /// 但它开了一个洞：一个在 idle / waiting 之间来回翻的会话，每翻一次就从
    /// 第 0 轮重来，于是**既不升级、也永远撞不到 5 次上限**，可以无限期地
    /// 每隔几分钟弹一次同一个项目。
    ///
    /// 给重置本身封顶：超过之后原因照常更新，但轮次不再归零，
    /// 阶梯继续往上走，最终照样会闭嘴。
    public var maxLadderRestarts = 2

    /// 卡了这么久还没人管，就**彻底不再主动闯入**，只留跑马灯和下唇染色。
    ///
    /// 同时顺手解决了另一个场景：app 重启时会一次性看到几个已经 idle 了
    /// 一两天的会话。它们的 `since` 早就超过这个阈值，于是启动瞬间不会
    /// 被一串闯入淹没 —— 信息还在岛上，只是不吵。
    public var giveUpAfter: TimeInterval = 2 * 3600

    public init() {}

    /// 第 n 轮该在"开始卡住"之后多久触发。
    func delay(forRound round: Int) -> TimeInterval {
        if round < steps.count { return steps[round] }
        return steps.last! + repeatInterval * TimeInterval(round - steps.count + 1)
    }
}

/// 把"哪些会话卡住了"翻译成"什么时候喊、喊几次、什么时候闭嘴"。
///
/// **纯状态机**：不碰时钟、不碰 UI，`now` 一律显式传入。
/// 升级阶梯的时序必须能在测试里跑完，不能真的等 20 分钟。
public struct NudgeCoordinator: Sendable {

    public var ladder: NudgeLadder

    /// 每个会话的跟踪状态。
    private struct Tracked: Sendable {
        var reason: StallReason
        var grade: StallGrade
        /// **当前这件事**从何时开始。原因一变就跟着变。
        var since: Date
        /// 这个会话**连续卡着**从何时开始 —— 原因变了也**不**重置。
        ///
        /// `giveUpAfter` 必须按它算而不是按 `since`：否则一个来回翻状态的会话
        /// 每翻一次 `since` 就被推到现在，"卡了两小时"这个条件永远够不着，
        /// 两道上限会同时失效。
        var firstSeenAt: Date
        /// 因原因变化重置过几次阶梯。见 `NudgeLadder.maxLadderRestarts`。
        var restarts = 0
        /// 已经主动喊过几次。
        var rounds: Int = 0
        /// **第一次喊的时刻。阶梯从这里开始计时，不是从 `since`。**
        ///
        /// 从 `since` 算是错的，实机上立刻翻车：一个被发现时已经 idle 了 4 分钟的
        /// 会话，一次就同时满足第 0 轮（≥0 秒）和第 1 轮（≥180 秒），
        /// 于是下一次扫描（30 秒后）又喊一遍 —— 实测两轮只隔了 16 秒。
        /// 任何"发现时就已经卡了一会儿"的会话都会这样连珠炮，
        /// 而那恰恰是最常见的情况（app 刚启动、或者刚满阈值才被判出来）。
        var firstNudgedAt: Date?
        /// 用户已经受理过一次（跳转或应答），跳过下一轮。
        var skipNext = false
    }

    private var tracked: [String: Tracked] = [:]

    public init(ladder: NudgeLadder = NudgeLadder()) {
        self.ladder = ladder
    }

    /// 当前所有卡住的会话，**含已经放弃主动闯入的**。
    ///
    /// 跑马灯和下唇染色用这个 —— 放弃"闯入"不等于放弃"告知"，
    /// 信息必须一直在岛上留着。
    public private(set) var passive: [StallFinding] = []

    /// 喂进最新一轮判定，拿回这一刻要不要主动提醒。
    ///
    /// - Returns: 需要主动闯入时返回 `Nudge`，否则 `nil`（但 `passive` 照常更新）。
    public mutating func update(findings: [StallFinding], now: Date) -> Nudge? {
        let current = Set(findings.map(\.sessionId))

        // 不再卡着的会话直接丢掉状态。下次再卡住时从第 0 轮重新开始 ——
        // 这正是我们要的：用户处理过之后，新的一次滞留是新的一件事。
        tracked = tracked.filter { current.contains($0.key) }

        var due: [StallFinding] = []
        var maxRound = 0

        for finding in findings {
            var entry = tracked[finding.sessionId] ?? Tracked(
                reason: finding.reason, grade: finding.grade,
                since: finding.since, firstSeenAt: finding.since
            )

            // 原因变了（比如从"待验收"升级成"断线"）就重新计时：
            // 那是一件新的事，不该沿用旧的轮次。
            //
            // 但**重置本身有次数上限** —— 见 maxLadderRestarts。超过之后
            // 原因照常更新，轮次不再归零，阶梯继续往上走直到闭嘴。
            if entry.reason != finding.reason {
                entry.reason = finding.reason
                entry.restarts += 1
                if entry.restarts <= ladder.maxLadderRestarts {
                    entry.rounds = 0
                    entry.firstNudgedAt = nil
                    entry.skipNext = false
                }
            }
            entry.grade = finding.grade
            entry.since = finding.since

            defer { tracked[finding.sessionId] = entry }

            // 低优只上跑马灯和染色，永不主动闯入。
            guard finding.grade == .high else { continue }
            guard entry.rounds < ladder.maxActiveRounds else { continue }
            // 卡太久的一次都不喊。**按 firstSeenAt 算**，不是按 since ——
            // 后者会随原因变化被推到现在，让这道上限永远够不着。
            guard now.timeIntervalSince(entry.firstSeenAt) < ladder.giveUpAfter
            else { continue }

            // 阶梯**按第一次喊的时刻**算。见 Tracked.firstNudgedAt。
            let elapsed = entry.firstNudgedAt.map { now.timeIntervalSince($0) } ?? 0
            guard elapsed >= ladder.delay(forRound: entry.rounds) else { continue }

            if entry.skipNext {
                // 用户刚受理过，这一轮不喊，但轮次照走 —— 否则会一直卡在同一轮。
                entry.skipNext = false
                entry.rounds += 1
                continue
            }

            if entry.firstNudgedAt == nil { entry.firstNudgedAt = now }
            due.append(finding)
            maxRound = max(maxRound, entry.rounds)
            entry.rounds += 1
        }

        passive = findings.sorted { lhs, rhs in
            if lhs.reason.priority != rhs.reason.priority {
                return lhs.reason.priority < rhs.reason.priority
            }
            return lhs.since < rhs.since
        }

        guard !due.isEmpty else { return nil }
        return Nudge(
            findings: due.sorted { $0.reason.priority < $1.reason.priority },
            round: maxRound,
            // 第一轮不出声。刚停下来就叫会显得过于急躁，
            // 而这时候用户很可能就在这台机器前面。
            sound: maxRound >= 1,
            // 见 Nudge.renotify：到这一档必须换 identifier 才会重新弹横幅。
            renotify: maxRound >= 2
        )
    }

    /// 用户受理了（跳到终端、或在岛上答了）。
    ///
    /// **只压制一轮，不永久清除** —— 跳过去看了一眼不等于处理完了。
    /// 真正的"处理完"是会话重新开工，那时 `findings` 里就没它了，状态自然清掉。
    public mutating func acknowledge(sessionId: String) {
        tracked[sessionId]?.skipNext = true
    }

    /// 某个会话当前喊到第几轮了。调试和测试用。
    public func rounds(for sessionId: String) -> Int {
        tracked[sessionId]?.rounds ?? 0
    }

    /// 是否已经放弃对这个会话的主动闯入（只剩被动提示）。
    public func hasGivenUp(on sessionId: String, now: Date) -> Bool {
        guard let entry = tracked[sessionId] else { return false }
        return entry.rounds >= ladder.maxActiveRounds
            || now.timeIntervalSince(entry.firstSeenAt) >= ladder.giveUpAfter
    }

    /// 这个会话因原因变化重置过几次阶梯。测试和排障用。
    public func restarts(for sessionId: String) -> Int {
        tracked[sessionId]?.restarts ?? 0
    }
}
