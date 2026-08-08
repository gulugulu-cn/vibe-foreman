import Foundation

/// 去仓库里找一条要点有没有留下痕迹。
///
/// ## 为什么必须有这条路
///
/// 现有的复核（`AcceptanceAuditor`）**只在它自报做完时才跑**。
/// 它压根不提的事情，没有任何东西会去查 —— 于是三份训练素材发过去两小时，
/// 一个都没接，而系统里没有任何机制会发现这件事，是用户先问的。
///
/// 「它停了就催」防的是偷懒；「它说做完了就核」防的是虚报。
/// **都防不住「它假装这事不存在」** —— 这一层补的正是这个缺口。
///
/// ## 判据只用「有没有痕迹」，不判「做得对不对」
///
/// 找到痕迹 ≠ 做对了，那是 auditor 的事。这里只回答一个便宜且确定的问题：
/// **仓库里有没有任何东西提到过它。** 零痕迹是个极强的信号 ——
/// 干过的事不可能一点印子都不留。
public enum RepoTrace {

    /// 从要点文本里挑出能拿去搜的关键词。
    ///
    /// 挑的原则是**宁缺毋滥**：搜不到关键词就返回空，让调用方跳过这条，
    /// 而不是拿「训练」「验证」这种词去搜 —— 那种搜什么都能命中，
    /// 反而会把「有痕迹」这个信号稀释成噪音。
    ///
    /// 认三类：
    /// - 引号 / 书名号里的名字（`「product-viability」`、`"选品"`）
    /// - 看着像路径或标识符的（`config/default-agents`、`record-trajectory.sh`）
    /// - 连字符连接的英文（`ecommerce-product-selection`）—— skill / 目录名的典型形态
    public static func keywords(from text: String) -> [String] {
        var found: [String] = []

        // 引号里的
        for pattern in [#"「([^」]{2,40})」"#, #""([^"]{2,40})""#, #"『([^』]{2,40})』"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                found.append(String(text[r]))
            }
        }

        // 路径 / 带连字符或点的标识符
        if let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9_]+(?:[-./][A-Za-z0-9_]+)+"#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                let token = String(text[r])
                // 太短的（a.b）和纯版本号（0.2.101）不要 —— 搜出来全是噪音。
                guard token.count >= 8, !token.allSatisfy({ $0.isNumber || $0 == "." })
                else { continue }
                found.append(token)
            }
        }

        // 去重，保序，最多 3 个 —— 搜太多次不值。
        var seen = Set<String>()
        return found.filter { seen.insert($0.lowercased()).inserted }.prefix(3).map { $0 }
    }

    /// 仓库里有没有提到过这个关键词。
    ///
    /// 三处都找：最近的 commit 信息、被改过的文件名、现存的目录/文件名。
    /// 任一命中就算有痕迹。
    public static func hasTrace(_ keyword: String, cwd: String) -> Bool {
        guard keyword.count >= 3 else { return true }   // 太短就别判，当成有

        // commit 信息
        if let log = run(cwd, ["log", "--oneline", "--since=7.days", "-i", "--grep", keyword]),
           !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        // 最近改过的文件名
        if let files = run(cwd, ["log", "--since=7.days", "--name-only", "--pretty=format:"]),
           files.lowercased().contains(keyword.lowercased()) {
            return true
        }
        // 现存的文件/目录名（未提交的也算）
        if let tracked = run(cwd, ["ls-files"]),
           tracked.lowercased().contains(keyword.lowercased()) {
            return true
        }
        return false
    }

    /// 一条要点在仓库里有没有痕迹。
    ///
    /// - Returns: nil = 判不了（挑不出关键词，或者不是 git 仓库）；
    ///            非 nil = 判了，值是那个一个痕迹都没有的关键词。
    public static func missingTrace(for text: String, cwd: String) -> String? {
        guard GitDiff.isRepository(cwd) else { return nil }
        let words = keywords(from: text)
        guard !words.isEmpty else { return nil }
        // 只要有一个关键词能找到痕迹就算这条有动静 —— 宁可漏报，不可误告。
        for word in words where hasTrace(word, cwd: cwd) { return nil }
        return words[0]
    }

    private static func run(_ cwd: String, _ args: [String]) -> String? {
        let result = Shell.run(GitDiff.git, ["-C", cwd] + args, timeout: 15)
        return result.succeeded ? result.stdout : nil
    }
}
