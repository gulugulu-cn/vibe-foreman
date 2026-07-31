import XCTest
@testable import HubProbe

final class NudgeCoordinatorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func finding(
        _ id: String = "s1",
        reason: StallReason = .finishedAwaitingReview(summary: nil, workedFor: 1800),
        grade: StallGrade = .high,
        since: Date? = nil
    ) -> StallFinding {
        StallFinding(sessionId: id, reason: reason, grade: grade, since: since ?? t0)
    }

    // MARK: - 阶梯时序

    /// 0 / 3 / 8 / 20 分钟四档，中间不该多喊。
    func testLadderFiresAtExpectedOffsets() {
        var coordinator = NudgeCoordinator()
        let f = [finding()]

        var fired: [Int] = []
        for minute in 0...25 {
            let now = t0.addingTimeInterval(TimeInterval(minute * 60))
            if let nudge = coordinator.update(findings: f, now: now) {
                fired.append(minute)
                XCTAssertEqual(nudge.findings.count, 1)
            }
        }
        XCTAssertEqual(fired, [0, 3, 8, 20])
    }

    /// **实机翻车的那个场景**：会话被发现时已经卡了一会儿。
    ///
    /// 阶梯如果按 `since` 计时，一个已经 idle 4 分钟的会话会一次同时满足
    /// 第 0 轮（≥0 秒）和第 1 轮（≥180 秒），下一次扫描（30 秒后）立刻再喊 ——
    /// 实测两轮只隔了 16 秒。而"发现时已经卡了一会儿"恰恰是最常见的情况。
    ///
    /// 原来那条 `testLadderFiresAtExpectedOffsets` 让 `since` 和 `now` 从同一
    /// 时刻起步，正好避开了这个场景，所以没测出来。
    func testLadderCountsFromFirstNudgeNotFromStallStart() {
        var coordinator = NudgeCoordinator()
        // 被发现时已经卡了 4 分钟 —— 早就越过了第 1 轮的 3 分钟门槛。
        let f = [finding(since: t0.addingTimeInterval(-240))]

        XCTAssertNotNil(coordinator.update(findings: f, now: t0), "第 0 轮该立刻喊")

        // 30 秒后的下一次扫描**不该**再喊 —— 距离第一次才 30 秒。
        XCTAssertNil(
            coordinator.update(findings: f, now: t0.addingTimeInterval(30)),
            "第 1 轮必须等到第一次提醒之后 3 分钟，不是从卡住那一刻算"
        )
        XCTAssertNil(coordinator.update(findings: f, now: t0.addingTimeInterval(170)))
        XCTAssertNotNil(
            coordinator.update(findings: f, now: t0.addingTimeInterval(181)),
            "第一次提醒之后满 3 分钟应该喊第 1 轮"
        )
    }

    /// 第一轮静默，第二轮起出声，第三轮起重发通知。
    func testSoundAndRenotifyEscalate() {
        var coordinator = NudgeCoordinator()
        let f = [finding()]

        let first = coordinator.update(findings: f, now: t0)
        XCTAssertEqual(first?.sound, false)
        XCTAssertEqual(first?.renotify, false)

        let second = coordinator.update(findings: f, now: t0.addingTimeInterval(180))
        XCTAssertEqual(second?.sound, true)
        XCTAssertEqual(second?.renotify, false)

        let third = coordinator.update(findings: f, now: t0.addingTimeInterval(480))
        XCTAssertEqual(third?.sound, true)
        XCTAssertEqual(third?.renotify, true)
    }

    // MARK: - 上限（这一条是拿真实数据逼出来的）

    /// 本机真有一个 idle 了 46 小时的会话。不封顶的话会主动弹 138 次。
    func testStopsIntrudingAfterMaxRounds() {
        var coordinator = NudgeCoordinator()
        let f = [finding()]

        var count = 0
        // 走 24 小时，每分钟问一次。
        for minute in 0...(24 * 60) {
            let now = t0.addingTimeInterval(TimeInterval(minute * 60))
            if coordinator.update(findings: f, now: now) != nil { count += 1 }
        }
        XCTAssertEqual(count, 5, "主动闯入必须封顶在 maxActiveRounds")
        XCTAssertTrue(coordinator.hasGivenUp(on: "s1", now: t0.addingTimeInterval(86400)))
    }

    /// 卡得太久的（比如 app 重启时看到的隔夜会话）一次都不主动闯入。
    /// 否则启动那一瞬间会被一串闯入淹没。
    func testStaleStallNeverIntrudes() {
        var coordinator = NudgeCoordinator()
        let old = finding(since: t0.addingTimeInterval(-46 * 3600))

        XCTAssertNil(coordinator.update(findings: [old], now: t0))
        XCTAssertEqual(coordinator.passive.count, 1, "不闯入，但信息必须留在岛上")
    }

    // MARK: - 分级

    func testLowGradeNeverIntrudesButStaysPassive() {
        var coordinator = NudgeCoordinator()
        let low = [finding(grade: .low)]

        for minute in 0...30 {
            let now = t0.addingTimeInterval(TimeInterval(minute * 60))
            XCTAssertNil(coordinator.update(findings: low, now: now), "低优不该主动闯入")
        }
        XCTAssertEqual(coordinator.passive.count, 1)
    }

    // MARK: - 合并

    /// 三个会话同时卡住只喊一次，不排队弹三次。
    func testMultipleSessionsMergeIntoOneNudge() {
        var coordinator = NudgeCoordinator()
        let findings = [
            finding("a", reason: .finishedAwaitingReview(summary: nil, workedFor: 1800)),
            finding("b", reason: .interrupted("断了")),
            finding("c", reason: .askedQuestion("要继续吗？")),
        ]
        let nudge = coordinator.update(findings: findings, now: t0)
        XCTAssertEqual(nudge?.findings.count, 3)
        // 展示顺序按优先级：断线 → 提问 → 待验收
        XCTAssertEqual(nudge?.findings.map(\.sessionId), ["b", "c", "a"])
    }

    // MARK: - 受理与清除

    /// 跳过去看了一眼只压制一轮，不是永久闭嘴。
    func testAcknowledgeSkipsExactlyOneRound() {
        var coordinator = NudgeCoordinator()
        let f = [finding()]

        XCTAssertNotNil(coordinator.update(findings: f, now: t0))
        coordinator.acknowledge(sessionId: "s1")

        XCTAssertNil(
            coordinator.update(findings: f, now: t0.addingTimeInterval(180)),
            "受理后的下一轮应被压制"
        )
        XCTAssertNotNil(
            coordinator.update(findings: f, now: t0.addingTimeInterval(480)),
            "再下一轮应该恢复"
        )
    }

    /// 会话不再卡着（重新开工了）就清空状态，
    /// 下次再停下来是**一件新的事**，从第 0 轮重新开始。
    func testResolvedSessionResetsTheLadder() {
        var coordinator = NudgeCoordinator()
        let f = [finding()]

        _ = coordinator.update(findings: f, now: t0)
        _ = coordinator.update(findings: f, now: t0.addingTimeInterval(180))
        XCTAssertEqual(coordinator.rounds(for: "s1"), 2)

        // 重新开工，列表里没它了
        XCTAssertNil(coordinator.update(findings: [], now: t0.addingTimeInterval(200)))
        XCTAssertEqual(coordinator.rounds(for: "s1"), 0)
        XCTAssertTrue(coordinator.passive.isEmpty)

        // 又停下来了 —— 立刻能喊，不受上一轮影响
        let again = finding(since: t0.addingTimeInterval(300))
        XCTAssertNotNil(
            coordinator.update(findings: [again], now: t0.addingTimeInterval(300))
        )
    }

    /// 原因升级（待验收 → 断线）要重新计时，不沿用旧轮次。
    func testReasonChangeRestartsTheLadder() {
        var coordinator = NudgeCoordinator()
        _ = coordinator.update(findings: [finding()], now: t0)
        _ = coordinator.update(findings: [finding()], now: t0.addingTimeInterval(180))
        XCTAssertEqual(coordinator.rounds(for: "s1"), 2)

        let escalated = finding(
            reason: .interrupted("连接中断"), since: t0.addingTimeInterval(200)
        )
        let nudge = coordinator.update(
            findings: [escalated], now: t0.addingTimeInterval(200)
        )
        XCTAssertNotNil(nudge, "换了原因应该立刻重新喊")
        XCTAssertEqual(nudge?.round, 0, "轮次要归零")
    }

    // MARK: - 反复变原因时的封顶

    /// **在 idle / waiting 之间来回翻的会话不能无限期地弹。**
    ///
    /// "原因变了就重新计时"本身是对的，但它开了个洞：每翻一次从第 0 轮重来，
    /// 于是既不升级、也永远撞不到 maxActiveRounds。
    /// 封顶之后原因照常更新，但轮次不再归零，阶梯继续往上走直到闭嘴。
    func testOscillatingReasonCannotNudgeForever() {
        var coordinator = NudgeCoordinator()
        let reasons: [StallReason] = [
            .finishedAwaitingReview(summary: nil, workedFor: 1800),
            .awaitingDecision("input needed"),
        ]

        var firedAt: [Int] = []
        // 90 分钟，每 5 分钟翻一次原因 —— 恰好是最坏的骚扰节奏。
        for i in 0..<18 {
            let now = t0.addingTimeInterval(TimeInterval(i * 300))
            let f = [finding(reason: reasons[i % 2], since: now)]
            if coordinator.update(findings: f, now: now) != nil { firedAt.append(i) }
        }

        // 真正要保证的性质是**最终会安静**，不是某个具体的次数 ——
        // 允许的重置各带一个第 0 轮，所以总数比 maxActiveRounds 大一些是正常的。
        XCTAssertGreaterThan(firedAt.count, 0, "头几次该喊")
        XCTAssertLessThan(firedAt.count, 18, "不能每次翻转都喊")
        XCTAssertLessThan(
            firedAt.last ?? 0, 12,
            "最后半小时必须完全安静，实际最后一次在第 \(firedAt.last ?? -1) 个五分钟"
        )
        XCTAssertTrue(
            coordinator.hasGivenUp(on: "s1", now: t0.addingTimeInterval(90 * 60)),
            "翻到最后必须进入只做被动提示的状态"
        )
    }

    /// `giveUpAfter` 必须按"连续卡着从何时开始"算。
    ///
    /// 按 `since` 算的话，原因一变 `since` 就被推到现在，
    /// "卡了两小时"这个条件永远够不着 —— 两道上限会同时失效。
    func testGiveUpUsesFirstSeenNotTheLatestReasonChange() {
        var coordinator = NudgeCoordinator()

        // 第一次见到就已经卡了 2 小时以上 —— 本来就该只做被动提示。
        let stale = t0.addingTimeInterval(-3 * 3600)
        _ = coordinator.update(
            findings: [finding(reason: .awaitingDecision("x"), since: stale)], now: t0
        )
        XCTAssertTrue(coordinator.hasGivenUp(on: "s1", now: t0))

        // 换个原因、since 推到现在 —— 不该因此复活。
        let fresh = t0.addingTimeInterval(60)
        let nudge = coordinator.update(
            findings: [finding(reason: .interrupted("断了"), since: fresh)], now: fresh
        )
        XCTAssertNil(nudge, "换原因不该绕过 giveUpAfter")
        XCTAssertTrue(coordinator.hasGivenUp(on: "s1", now: fresh))
    }

    /// 但**正常的一次升级**仍然要能重新计时 —— 封顶不能把它一起封死。
    func testFirstFewReasonChangesStillRestart() {
        var coordinator = NudgeCoordinator()
        _ = coordinator.update(findings: [finding()], now: t0)
        _ = coordinator.update(findings: [finding()], now: t0.addingTimeInterval(180))
        XCTAssertEqual(coordinator.rounds(for: "s1"), 2)

        let escalated = finding(reason: .interrupted("断了"), since: t0.addingTimeInterval(200))
        let nudge = coordinator.update(
            findings: [escalated], now: t0.addingTimeInterval(200)
        )
        XCTAssertEqual(nudge?.round, 0, "第一次换原因该重新计时")
        XCTAssertEqual(coordinator.restarts(for: "s1"), 1)
    }

    /// 会话真的恢复了（从列表里消失）之后，重置计数也要清零 ——
    /// 否则一个用了很久的会话会因为历史上的几次翻转而再也不能重新计时。
    func testResolvingClearsTheRestartBudget() {
        var coordinator = NudgeCoordinator()
        let reasons: [StallReason] = [
            .finishedAwaitingReview(summary: nil, workedFor: 1800),
            .awaitingDecision("x"),
            .interrupted("断了"),
        ]
        for (i, reason) in reasons.enumerated() {
            let now = t0.addingTimeInterval(TimeInterval(i * 400))
            _ = coordinator.update(findings: [finding(reason: reason, since: now)], now: now)
        }
        XCTAssertGreaterThan(coordinator.restarts(for: "s1"), 0)

        // 重新开工
        _ = coordinator.update(findings: [], now: t0.addingTimeInterval(2000))
        XCTAssertEqual(coordinator.restarts(for: "s1"), 0)
    }

    // MARK: - 被动列表

    func testPassiveIsSortedByPriority() {
        var coordinator = NudgeCoordinator()
        _ = coordinator.update(findings: [
            finding("a", reason: .finishedAwaitingReview(summary: nil, workedFor: 10), grade: .low),
            finding("b", reason: .awaitingDecision("授权")),
            finding("c", reason: .interrupted("断了")),
        ], now: t0)
        XCTAssertEqual(coordinator.passive.map(\.sessionId), ["c", "b", "a"])
    }
}
