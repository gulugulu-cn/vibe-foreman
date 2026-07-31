import Foundation
import HubCore
import HubProbe

/// 把探针、AI、升级阶梯和岛串起来的那根线。
///
/// 每 30 秒扫一轮：读 transcript 尾部和任务清单 → 判定 → 需要时问 AI →
/// 交给 `NudgeCoordinator` 决定这一刻要不要喊。
///
/// 磁盘 IO 和 `claude -p` 都在后台线程，主线程只负责最后那一下状态更新。
@MainActor
public final class StallWatcher {

    private let store: SessionStore
    private let detector: StallDetector
    private let judge: StallJudge
    private var coordinator: NudgeCoordinator
    private let transcripts = TranscriptReader()
    private let taskReader = TaskStateReader()

    /// 该主动喊了。
    public var onNudge: ((Nudge) -> Void)?
    /// 当前卡着的全部（含已不再主动闯入的）。跑马灯和下唇染色用。
    public var onStalledChanged: (([StallFinding]) -> Void)?
    /// AI 给出的快捷回答选项。岛上应答态的按钮用。
    public var onOptions: ((String, [String]) -> Void)?

    private var timer: Timer?
    private var scanning = false

    /// AI 结论的缓存。会话内容没变就没必要重问 —— 一次 9 秒、要花钱。
    private var summaries: [String: StallSummary] = [:]
    /// 缓存对应的那条回复。回复变了才作废。
    private var summarySource: [String: String] = [:]

    public init(
        store: SessionStore,
        detector: StallDetector = StallDetector(),
        judge: StallJudge = StallJudge(),
        coordinator: NudgeCoordinator = NudgeCoordinator()
    ) {
        self.store = store
        self.detector = detector
        self.judge = judge
        self.coordinator = coordinator
    }

    /// 扫描间隔。
    ///
    /// 30 秒足够了：这里判的是"停了三分钟以上"这类事，一秒一扫毫无意义，
    /// 而每一轮都要读几个会话的 transcript 尾部 + 任务目录。
    private static let interval: TimeInterval = 30

    public func start() {
        stop()
        // 启动后先等一轮再扫：app 刚起来时 store 还没读到会话。
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 用户受理了某个滞留（在岛上点了它，或者答了）。压制一轮升级。
    public func acknowledge(_ sessionId: String) {
        coordinator.acknowledge(sessionId: sessionId)
    }

    public func scan() {
        guard !scanning else { return }

        // 只看停下来的。busy / shell 正在干活，连文件都不用读。
        let candidates = store.sessions.filter {
            $0.status == .idle || $0.status == .waiting
        }
        let durations = store.lastWorkDuration

        guard !candidates.isEmpty else {
            apply(findings: [], now: Date())
            return
        }
        scanning = true

        let transcripts = self.transcripts
        let taskReader = self.taskReader
        let detector = self.detector
        let judge = self.judge

        Task { [weak self] in
            // ① 磁盘部分放后台。
            let probes = await Task.detached(priority: .utility) {
                candidates.map { session in
                    Probe(
                        session: session,
                        tail: transcripts.read(cwd: session.cwd, sessionId: session.sessionId),
                        tasks: taskReader.read(sessionId: session.sessionId)
                    )
                }
            }.value

            guard let self else { return }
            let cachedSummaries = self.summaries
            let cachedSources = self.summarySource

            // ② 先不带 AI 判一遍，判出卡住的才值得花额度。
            var inputs: [String: StallDetector.Input] = [:]
            var needsAI: [(String, String)] = []
            let now = Date()

            for probe in probes {
                let text = probe.tail?.lastAssistantText
                // 缓存只在"这条回复没变"时有效。
                let cached = (cachedSources[probe.session.sessionId] == text)
                    ? cachedSummaries[probe.session.sessionId] : nil

                let input = StallDetector.Input(
                    session: probe.session, tail: probe.tail, tasks: probe.tasks,
                    busyDuration: durations[probe.session.sessionId], ai: cached
                )
                inputs[probe.session.sessionId] = input

                if cached == nil, detector.evaluate(input, now: now) != nil,
                   let text, !text.isEmpty {
                    needsAI.append((probe.session.sessionId, text))
                }
            }

            // ③ 串行问 AI。并发起好几个 claude 进程既慢又费额度，
            //    而这本来就是个后台任务，没人在等它。
            for (sessionId, text) in needsAI {
                guard await judge.shouldJudge(sessionId: sessionId, now: now) else { continue }
                guard let summary = await judge.judge(
                    sessionId: sessionId, assistantText: text, now: now
                ) else { continue }

                await MainActor.run {
                    self.summaries[sessionId] = summary
                    self.summarySource[sessionId] = text
                    if !summary.options.isEmpty {
                        self.onOptions?(sessionId, summary.options)
                    }
                }
                if let old = inputs[sessionId] {
                    inputs[sessionId] = StallDetector.Input(
                        session: old.session, tail: old.tail, tasks: old.tasks,
                        busyDuration: old.busyDuration, ai: summary
                    )
                }
            }

            // ④ 带上 AI 结论重新判一遍，交给阶梯。
            let findings = inputs.values.compactMap { detector.evaluate($0, now: now) }

            await MainActor.run {
                self.scanning = false
                self.apply(findings: findings, now: now)
                self.pruneCaches(alive: Set(candidates.map(\.sessionId)))
            }
        }
    }

    private struct Probe: Sendable {
        let session: AgentSession
        let tail: TranscriptTail?
        let tasks: TaskSnapshot?
    }

    private func apply(findings: [StallFinding], now: Date) {
        let nudge = coordinator.update(findings: findings, now: now)
        onStalledChanged?(coordinator.passive)
        if let nudge { onNudge?(nudge) }
    }

    /// 会话没了就把缓存清掉，别让字典无限涨。
    private func pruneCaches(alive: Set<String>) {
        summaries = summaries.filter { alive.contains($0.key) }
        summarySource = summarySource.filter { alive.contains($0.key) }
    }
}
