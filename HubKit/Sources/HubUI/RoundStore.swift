import Foundation
import HubCore
import HubProjects
import Observation

/// 轮次时间轴的仓库。一个项目一份日志，新的在前。
///
/// 持久化纪律整套照抄 `AcceptanceStore`（那边的每条注释背后都是一次事故）：
/// - 目录可注入，nil = 不落盘 —— 测试不许碰用户真实数据；
/// - mutate 写前先 reload —— 外部手改不被覆盖；
/// - 解不出来的文件改名 `.broken-<ts>` 保住，绝不静默盖掉；
/// - 逐条容错解码，一条坏的不连累整份。
@Observable
@MainActor
public final class RoundStore {

    /// 全部日志，key = 项目绝对路径。
    public private(set) var logs: [String: RoundLog] = [:]

    /// 每项目最多留多少轮。超出从最老的丢 —— 时间轴是近期工作的仪表，
    /// 不是永久档案（导出/git 历史才是档案）。
    public static let cap = 200

    /// app 重启遗留的未收口轮：超过这个时长就在启动时补收口，
    /// 别让时间轴上永远挂着一个「进行中」。
    private static let staleOpenAge: TimeInterval = 24 * 3600

    @ObservationIgnored
    private let directory: URL?

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/rounds")
    }

    public init(directory: URL? = RoundStore.defaultDirectory) {
        self.directory = directory
        loadAll()
    }

    // MARK: - 轮次边界

    /// UserPromptSubmit：开轮，或并入当前未收口的轮。
    ///
    /// 同一会话已有未收口的轮时只 promptCount += 1 —— Claude 干活途中
    /// 用户补一句"顺便把 X 也改了"是常态，不该被记成两轮。
    /// 返回轮 id（新开的或并入的那个）。
    @discardableResult
    public func beginRound(
        sessionId: String, projectPath: String, prompt: String, baseline: String? = nil
    ) -> String {
        var roundId = ""
        mutate(projectPath) { log in
            if let index = log.rounds.firstIndex(where: {
                $0.sessionId == sessionId && $0.endedAt == nil
            }) {
                log.rounds[index].promptCount += 1
                roundId = log.rounds[index].id
                return
            }
            let round = RoundRecord(
                sessionId: sessionId,
                projectPath: projectPath,
                promptSummary: RoundRecord.summarize(prompt: prompt),
                baselineCommit: baseline
            )
            log.rounds.insert(round, at: 0)
            roundId = round.id
        }
        return roundId
    }

    /// 开轮时不 fork git（hook 要立刻返回），HEAD 由后台任务拿到后补写。
    public func setBaseline(roundId: String, in projectPath: String, commit: String) {
        mutate(projectPath) { log in
            guard let index = log.rounds.firstIndex(where: { $0.id == roundId }),
                  log.rounds[index].baselineCommit == nil else { return }
            log.rounds[index].baselineCommit = commit
        }
    }

    /// Stop：收口。返回被收口的轮（供分析器用）。
    ///
    /// 没有未收口的轮（app 中途才启动、hook 漏了 UserPromptSubmit）时
    /// 兜底新建一条再收口 —— 时间轴上不能凭空少一轮。
    @discardableResult
    public func closeRound(
        sessionId: String, projectPath: String,
        touchedFileCount: Int, hadRealChanges: Bool, assistantSummary: String?
    ) -> RoundRecord? {
        var closed: RoundRecord?
        mutate(projectPath) { log in
            let index = log.rounds.firstIndex {
                $0.sessionId == sessionId && $0.endedAt == nil
            } ?? {
                let fallback = RoundRecord(
                    sessionId: sessionId, projectPath: projectPath,
                    promptSummary: "（未捕获到本轮提示）"
                )
                log.rounds.insert(fallback, at: 0)
                return 0
            }()
            log.rounds[index].endedAt = Date()
            log.rounds[index].touchedFileCount = touchedFileCount
            log.rounds[index].hadRealChanges = hadRealChanges
            log.rounds[index].assistantSummary = assistantSummary
            closed = log.rounds[index]
        }
        return closed
    }

    /// 观察者分析的结果异步补写。轮可能已被删/滚掉 —— 静默忽略，不复活。
    public func applyAnalysis(
        roundId: String, in projectPath: String,
        recap: String, verdicts: [RoundVerdict], diffStat: String?
    ) {
        mutate(projectPath) { log in
            guard let index = log.rounds.firstIndex(where: { $0.id == roundId }) else { return }
            log.rounds[index].recap = recap
            log.rounds[index].verdicts = verdicts
            if let diffStat { log.rounds[index].diffStat = diffStat }
            // 分析只在有实改的轮上跑 —— Claude 用 Bash 改文件时 PostToolUse
            // 抓不到，收口时误记成"纯问答"，门槛兜底查到实改后在这里纠正。
            log.rounds[index].hadRealChanges = true
        }
    }

    // MARK: - 查询与清理

    /// 新的在前。
    public func rounds(for projectPath: String) -> [RoundRecord] {
        logs[projectPath]?.rounds ?? []
    }

    /// 某会话当前未收口的轮。要点入库时靠它把条目挂到轮上。
    public func openRoundId(sessionId: String, projectPath: String) -> String? {
        logs[projectPath]?.rounds
            .first { $0.sessionId == sessionId && $0.endedAt == nil }?.id
    }

    public func remove(ids: Set<String>, in projectPath: String) {
        guard !ids.isEmpty else { return }
        mutate(projectPath) { log in
            log.rounds.removeAll { ids.contains($0.id) }
        }
    }

    // MARK: - 持久化（纪律同 AcceptanceStore.mutate）

    private func mutate(_ projectPath: String, _ body: (inout RoundLog) -> Void) {
        reload(projectPath)
        var log = logs[projectPath] ?? RoundLog(projectPath: projectPath)
        body(&log)
        if log.rounds.count > Self.cap {
            log.rounds = Array(log.rounds.prefix(Self.cap))
        }
        log.updatedAt = Date()
        logs[projectPath] = log
        persist(log)
    }

    private func fileURL(for projectPath: String) -> URL? {
        directory?.appendingPathComponent(
            UsageStats.encodeDirectoryName(for: projectPath) + ".json"
        )
    }

    private func reload(_ projectPath: String) {
        guard let url = fileURL(for: projectPath),
              let data = try? Data(contentsOf: url)
        else { return }

        if let log = try? JSONDecoder().decode(RoundLog.self, from: data) {
            logs[projectPath] = log
            return
        }

        let rescued = url.deletingPathExtension()
            .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: rescued)
        HubLog.app.error("""
        轮次日志解不出来，已保留为 \(rescued.lastPathComponent, privacy: .public)
        """)
    }

    private func persist(_ log: RoundLog) {
        guard let directory, let url = fileURL(for: log.projectPath) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadAll() {
        guard let directory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            guard var log = try? JSONDecoder().decode(RoundLog.self, from: data) else {
                let rescued = file.deletingPathExtension()
                    .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: file, to: rescued)
                HubLog.app.error("""
                启动时有轮次日志解不出来，已保留为 \(rescued.lastPathComponent, privacy: .public)
                """)
                continue
            }
            closeStaleRounds(&log)
            logs[log.projectPath] = log
        }
    }

    /// 隔夜遗留的未收口轮补收口：endedAt = startedAt，recap 留空。
    private func closeStaleRounds(_ log: inout RoundLog) {
        let cutoff = Date().addingTimeInterval(-Self.staleOpenAge)
        for index in log.rounds.indices
        where log.rounds[index].endedAt == nil && log.rounds[index].startedAt < cutoff {
            log.rounds[index].endedAt = log.rounds[index].startedAt
        }
    }
}
