import HubCore
import SwiftUI

/// 轮次时间轴：验收页的主体。
///
/// 一轮 = 用户敲回车到 Claude 收工。hub 是观察者 —— 每个节点回答
/// 「这一轮说了要做什么、实际改了什么」，代替以前那种把清单注入对话
/// 逼 Claude 自查的方式。样式对齐 `ApprovalLogPane`（同为时间流）。
struct RoundTimeline: View {
    let rounds: [RoundRecord]
    /// 点 verdict 里的文件时回溯 diff（复用验收页的 diff sheet）。
    let onOpenDiff: (_ path: String, _ round: RoundRecord) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        if rounds.isEmpty {
            ContentUnavailableView(
                "还没有轮次记录",
                systemImage: "clock.arrow.circlepath",
                description: Text("从下一轮对话开始，这里会记下每轮「说了什么 vs 实际改了什么」")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.groupByDay(rounds), id: \.label) { group in
                        Text(group.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        ForEach(group.rounds) { node($0) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - 节点

    @ViewBuilder
    private func node(_ round: RoundRecord) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Self.dotColor(for: round))
                        .frame(width: 7, height: 7)

                    Text(round.startedAt, style: .time)
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)

                    Text(round.promptSummary)
                        .font(.system(size: 13))
                        .lineLimit(expanded.contains(round.id) ? nil : 1)

                    if round.promptCount > 1 {
                        Text("\(round.promptCount) 句")
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 6)

                    HStack(spacing: 4) {
                        if Self.statusLine(for: round) == "分析中…" {
                            ProgressView().controlSize(.mini)
                        }
                        Text(Self.statusLine(for: round))
                            .font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(
                                round.hadRealChanges ? IslandTheme.shell : .secondary
                            )
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: .capsule)
                }
                .contentShape(.rect)
                .onTapGesture { toggle(round.id) }

                if let recap = round.recap {
                    Text(recap)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded.contains(round.id) ? nil : 2)
                        .padding(.leading, 15)
                }

                if expanded.contains(round.id) {
                    detail(round)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ round: RoundRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 逐条 verdict：这一轮里哪些参考条目被证实了、哪些还没影。
            ForEach(round.verdicts, id: \.itemId) { verdict in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: verdict.confirmed
                            ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 11))
                            .foregroundStyle(
                                verdict.confirmed ? IslandTheme.shell : .secondary
                            )
                        if let note = verdict.note {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(verdict.evidence.enumerated()), id: \.offset) { _, evidence in
                        HStack(spacing: 5) {
                            Text(evidence.shortLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if case .diff(let path, _, _) = evidence {
                                Button("看改动") { onOpenDiff(path, round) }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .padding(.leading, 17)
                    }
                }
            }

            // 分析没跑成 / 纯问答轮的兜底：Claude 自己的收工汇报压缩版。
            if round.recap == nil, let summary = round.assistantSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 15)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: - 可测的规则（渲染不测，规则要测）

    /// 节点右侧的状态行。「进行中 / 分析中 / 纯问答 / 有实改」必须一眼分开 ——
    /// 尤其是「分析中」：不显示的话节点看起来就是"没分析"，像是功能坏了。
    static func statusLine(for round: RoundRecord) -> String {
        guard round.endedAt != nil else { return "进行中" }
        guard round.hadRealChanges else { return "纯问答" }
        guard round.recap != nil else { return "分析中…" }
        if let diffStat = round.diffStat { return diffStat }
        if round.touchedFileCount > 0 { return "改了 \(round.touchedFileCount) 个文件" }
        return "有实改"
    }

    static func dotColor(for round: RoundRecord) -> Color {
        if round.endedAt == nil { return IslandTheme.busy }
        return round.hadRealChanges ? IslandTheme.shell : Color.secondary
    }

    /// 按天分组，保持传入顺序（新的在前）。
    static func groupByDay(
        _ rounds: [RoundRecord], calendar: Calendar = .current, now: Date = Date()
    ) -> [(label: String, rounds: [RoundRecord])] {
        var groups: [(label: String, rounds: [RoundRecord])] = []
        for round in rounds {
            let label = dayLabel(for: round.startedAt, calendar: calendar, now: now)
            if groups.last?.label == label {
                groups[groups.count - 1].rounds.append(round)
            } else {
                groups.append((label, [round]))
            }
        }
        return groups
    }

    static func dayLabel(for date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        let components = calendar.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }
}
