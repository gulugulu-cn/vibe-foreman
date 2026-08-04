import Foundation
import HubProbe

/// 采集 git 状态。
///
/// 用 `--porcelain=v2 --branch` **一次调用**拿全部信息（分支、上游、ahead/behind、
/// 变更数）。分开跑 `git branch` / `git status` / `git rev-list` 是三次 fork，
/// 21 个项目就是 63 次进程创建。
public enum GitStatus {

    public static func collect(at path: String) -> GitInfo? {
        let result = Shell.run(
            "/usr/bin/git",
            ["-C", path, "status", "--porcelain=v2", "--branch"],
            timeout: 5
        )
        guard result.succeeded else { return nil }
        return parse(result.stdout, lastCommitAt: lastCommitDate(at: path))
    }

    /// 最后一次提交的时间。项目列表拿它排"最近在做的"。
    ///
    /// 多一次 fork，但实测 38 个仓库合计约 300ms（在后台队列上跑），
    /// 换来的是「38 个项目里一眼找到在做的那个」——这个交换值得。
    /// 空仓库（还没有任何提交）返回 nil。
    static func lastCommitDate(at path: String) -> Date? {
        let result = Shell.run(
            "/usr/bin/git",
            ["-C", path, "log", "-1", "--format=%ct"],
            timeout: 5
        )
        guard result.succeeded,
              let seconds = TimeInterval(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func parse(_ output: String, lastCommitAt: Date? = nil) -> GitInfo {
        var branch: String?
        var ahead = 0
        var behind = 0
        var hasUpstream = false
        var changes = 0

        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                // detached HEAD 时 git 输出字面量 "(detached)"。
                branch = value == "(detached)" ? nil : value
            } else if line.hasPrefix("# branch.upstream ") {
                hasUpstream = true
            } else if line.hasPrefix("# branch.ab ") {
                // 格式：`# branch.ab +3 -1`
                let parts = line.split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") && !line.isEmpty {
                // 非 `#` 开头的每一行都是一个变更条目
                // （1=普通变更 2=重命名 u=冲突 ?=未跟踪）。
                changes += 1
            }
        }

        return GitInfo(
            branch: branch, changeCount: changes,
            ahead: ahead, behind: behind, hasUpstream: hasUpstream,
            lastCommitAt: lastCommitAt
        )
    }

    /// 仓库根目录。
    ///
    /// 会话的 cwd 常常是仓库的子目录，而"当前目录"和"仓库"是两件事 ——
    /// 同一个项目多开时，几个会话可能落在不同的 worktree 里，
    /// 只看项目名会把它们混成一个。
    public static func repositoryRoot(at path: String) -> String? {
        let result = Shell.run(
            "/usr/bin/git", ["-C", path, "rev-parse", "--show-toplevel"], timeout: 5
        )
        guard result.succeeded else { return nil }
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// 最近几条提交。
    ///
    /// 用 `%x1f`（Unit Separator）分隔字段而不是制表符或竖线：提交标题里
    /// 出现制表符不常见但完全合法，出现 US 控制字符则基本不可能。
    public static func log(at path: String, limit: Int = 3) -> [GitCommit] {
        let result = Shell.run(
            "/usr/bin/git",
            [
                "-C", path, "log", "-\(limit)",
                "--pretty=format:%h%x1f%s%x1f%cr%x1f%an",
                "--no-color",
            ],
            timeout: 5
        )
        guard result.succeeded else { return [] }
        return parseLog(result.stdout)
    }

    static func parseLog(_ output: String) -> [GitCommit] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return nil }
            return GitCommit(
                hash: String(fields[0]),
                subject: String(fields[1]),
                relativeDate: String(fields[2]),
                author: fields.count > 3 ? String(fields[3]) : ""
            )
        }
    }

    /// 扫描目录树找 git 仓库。
    ///
    /// 命中 `.git` 就停止下钻 —— 不然会一路走进 vendor 目录里的子仓库，
    /// 扫出一堆用户根本不认识的"项目"。
    public static func scanRepositories(
        under root: String,
        maxDepth: Int = 3
    ) -> [String] {
        var found: [String] = []
        let skipped: Set<String> = ["node_modules", "target", "dist", "build", "vendor", "Pods"]

        func walk(_ path: String, depth: Int) {
            guard depth <= maxDepth else { return }

            if FileManager.default.fileExists(atPath: path + "/.git") {
                found.append(path)
                return   // 命中即停，不再下钻
            }

            guard let entries = try? FileManager.default
                .contentsOfDirectory(atPath: path) else { return }

            for entry in entries {
                guard !entry.hasPrefix("."), !skipped.contains(entry) else { continue }
                var isDirectory: ObjCBool = false
                let child = path + "/" + entry
                guard FileManager.default.fileExists(atPath: child, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                walk(child, depth: depth + 1)
            }
        }

        walk(NSString(string: root).expandingTildeInPath, depth: 0)
        return found
    }
}
