import Foundation

/// 读 git 的真实改动。
///
/// 验收清单里「治骗」的那一半靠它：旁路复核读的是这里产出的 diff，
/// 不是 Claude 说的话。
public enum GitDiff {

    /// **不能靠 PATH 找 git。** Hub 是 GUI app，从 launchd 起，
    /// PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`。
    /// `/usr/bin/git` 是 macOS 自带的 xcode-select 转发器，一定在。
    static let git = "/usr/bin/git"

    /// 一个文件的改动量。
    public struct FileChange: Sendable, Equatable {
        public let path: String
        public let added: Int
        public let removed: Int
    }

    public static func isRepository(_ cwd: String) -> Bool {
        run(cwd, ["rev-parse", "--git-dir"]) != nil
    }

    public static func head(_ cwd: String) -> String? {
        run(cwd, ["rev-parse", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 `since` 到现在的每个文件改了多少行。
    ///
    /// **必须带上未提交的改动**（`git diff <since>` 而不是
    /// `git diff <since> HEAD`）：Claude 刚干完活通常还没 commit，
    /// 只看已提交的部分等于把这一轮的成果全漏掉 —— 那样每一条都会被判成
    /// 「代码里找不到」，复核结论全是假阳性。
    public static func numstat(_ cwd: String, since: String?) -> [FileChange] {
        var args = ["diff", "--numstat"]
        if let since, !since.isEmpty { args.append(since) }
        guard let output = run(cwd, args) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            // 二进制文件的增删是 "-"，按 0 算。
            return FileChange(
                path: String(parts[2]),
                added: Int(parts[0]) ?? 0,
                removed: Int(parts[1]) ?? 0
            )
        }
    }

    /// 供人阅读的 diff 正文。`limit` 是字符上限。
    ///
    /// 上限是必须的：一次大重构的 diff 能有几十万字符，全喂给模型既烧钱
    /// 又会把真正相关的部分挤出上下文窗口。
    public static func patch(
        _ cwd: String, since: String?, paths: [String] = [], limit: Int = 24_000
    ) -> String {
        var args = ["diff"]
        if let since, !since.isEmpty { args.append(since) }
        if !paths.isEmpty {
            args.append("--")
            args.append(contentsOf: paths)
        }
        guard let output = run(cwd, args) else { return "" }
        guard output.count > limit else { return output }
        return String(output.prefix(limit)) + "\n…（diff 过长，已截断）"
    }

    /// 每个改动文件都露一段的 diff。
    ///
    /// ## 为什么不能直接截断整份 diff
    ///
    /// `git diff` 按文件名字母序输出。整份截断的话，排在前面的几个文件就把预算
    /// 吃光了，后面的文件**一行都进不到模型眼里**。
    ///
    /// 实测撞到过：复核 13 条要点，其中一条对应 `MainWindow.swift`（真的改了 79 行），
    /// 但它排在字母序后段，24KB 预算在它之前就用完了 —— 模型给的理由是
    /// 「实际 diff 未展示(被截断)，无法确认」，于是一条真做了的要点被判成存疑。
    ///
    /// **任何真实规模的改动都会这样**，所以这不是调大上限能解决的（多大都会被
    /// 吃光），必须按文件均分预算：每个文件都露一段，宁可每段短一点。
    ///
    /// - Parameter limit: 总字符预算。
    /// - Parameter minimumPerFile: 每个文件至少给多少字符 —— 太少的话
    ///   露出来的只有文件头，等于没露。文件多到连这个都保证不了时，
    ///   按改动量从大到小取，其余的只在概览里出现。
    public static func balancedPatch(
        _ cwd: String, since: String?, limit: Int = 40_000, minimumPerFile: Int = 1_200
    ) -> String {
        let changes = numstat(cwd, since: since)
        guard !changes.isEmpty else { return "" }

        // 改动大的优先 —— 一个文件被改了 400 行，它多半就是这一轮的主体。
        let ranked = changes.sorted { $0.added + $0.removed > $1.added + $1.removed }
        let affordable = max(1, limit / minimumPerFile)
        let selected = Array(ranked.prefix(affordable))
        let perFile = max(minimumPerFile, limit / selected.count)

        var parts: [String] = []
        for change in selected {
            let single = patch(cwd, since: since, paths: [change.path], limit: perFile)
            guard !single.isEmpty else { continue }
            parts.append(single)
        }

        if selected.count < ranked.count {
            let omitted = ranked.count - selected.count
            parts.append("…（另有 \(omitted) 个改动较小的文件没有展开，见上面的改动概览）")
        }
        return parts.joined(separator: "\n")
    }

    /// 一行一个文件的概览，给模型看的。
    public static func summary(_ cwd: String, since: String?) -> String {
        numstat(cwd, since: since)
            .map { "\($0.path)  +\($0.added) -\($0.removed)" }
            .joined(separator: "\n")
    }

    private static func run(_ cwd: String, _ args: [String]) -> String? {
        // -C 而不是改工作目录：Shell.run 是全进程共享的，改 cwd 会影响别的调用。
        let result = Shell.run(git, ["-C", cwd] + args, timeout: 20)
        guard result.succeeded else { return nil }
        return result.stdout
    }
}
