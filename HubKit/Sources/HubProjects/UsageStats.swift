import Foundation

/// 单个项目的 token 用量。
public struct ProjectUsage: Identifiable, Sendable {
    public let projectPath: String
    public let projectName: String
    public let sessionCount: Int
    public let messageCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let models: [String]

    public var id: String { projectPath }
    public var totalTokens: Int { inputTokens + outputTokens }
}

public struct UsageSummary: Sendable {
    public let projects: [ProjectUsage]
    public let totalSessions: Int
    public let totalMessages: Int
    public let totalInput: Int
    public let totalOutput: Int

    public static let empty = UsageSummary(
        projects: [], totalSessions: 0, totalMessages: 0, totalInput: 0, totalOutput: 0
    )
}

public enum UsageRange: String, CaseIterable, Sendable {
    case week7 = "7天"
    case month30 = "30天"
    case all = "全部"

    var cutoff: Date? {
        switch self {
        case .week7: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month30: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .all: return nil
        }
    }
}

/// 单个 jsonl 文件的统计小计。缓存的最小单位。
struct FileUsage: Codable, Sendable {
    let size: Int64
    let modified: Date
    let messages: Int
    let input: Int
    let output: Int
    let models: [String]
}

/// 从 `~/.claude/projects/<编码路径>/*.jsonl` 统计 token 用量。
///
/// 这些文件是 Claude Code 的会话记录。**实测本机有 945 MB / 341 个文件**，
/// 所以有两条硬性约束：
///
/// 1. **绝不把整个文件读成 `String`。** 原实现用 `String(contentsOf:)` 再
///    `split(separator: "\n")`，945 MB 全进内存再切分，页面永远停在 0 ——
///    用户看到的就是"用量功能没做"。改成 `FileHandle` 分块流式读取。
/// 2. **必须增量缓存。** jsonl 只追加不重写，同一个文件的 size + mtime 没变
///    就不该重算。缓存落盘，第二次打开秒出。
///
/// 行级别仍然做**子串预筛**：只有含 `"usage"` 的行才值得走 JSON 解析，
/// 实测能跳过 90% 以上的行。
public enum UsageStats {

    /// 流式读取的块大小。1 MB 是吞吐和内存的折中 —— 再大对总耗时几乎没影响，
    /// 但会让峰值内存跟着涨。
    private static let chunkSize = 1 << 20

    static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/usage-cache.json")
    }

    /// 目录名编码规则：路径里每个非 ASCII 字母数字字符替换成 `-`，不 trim。
    /// 例：`/Users/dev/Documents/code/claude-hub`
    ///  → `-Users-dev-Documents-code-claude-hub`
    public static func encodeDirectoryName(for path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// 反解目录名 → 大致的项目名（取最后一段）。
    static func projectName(fromEncoded encoded: String) -> String {
        encoded.split(separator: "-").last.map(String.init) ?? encoded
    }

    /// 统计用量。
    ///
    /// `progress` 每处理完一个文件回调一次 `(已完成, 总数)`，
    /// 用于「全部」范围下的进度显示 —— 首次全量要扫近 1 GB，没有进度条
    /// 用户没法区分"在算"和"坏了"。
    public static func collect(
        range: UsageRange,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> UsageSummary {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)

        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return .empty }

        let cutoff = range.cutoff
        var cache = loadCache()
        var cacheDirty = false
        var results: [ProjectUsage] = []

        // 先把要处理的文件数点出来，进度才有分母。
        var pending: [(dir: URL, files: [URL])] = []
        var totalFiles = 0
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: []
            ) else { continue }
            let jsonl = files.filter { $0.pathExtension == "jsonl" }
            guard !jsonl.isEmpty else { continue }
            pending.append((dir, jsonl))
            totalFiles += jsonl.count
        }

        var done = 0
        for entry in pending {
            var sessions = 0
            var messages = 0
            var input = 0
            var output = 0
            var models = Set<String>()

            for file in entry.files {
                defer {
                    done += 1
                    progress?(done, totalFiles)
                }

                let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                let modified = values?.contentModificationDate ?? .distantPast
                let size = Int64(values?.fileSize ?? 0)

                // 范围过滤放在读文件之前 —— 7 天视图下这一步就砍掉绝大多数文件。
                if let cutoff, modified < cutoff { continue }

                let key = file.path
                let stats: FileUsage
                if let cached = cache[key], cached.size == size, cached.modified == modified {
                    stats = cached
                } else {
                    guard let fresh = scanFile(file, size: size, modified: modified) else {
                        continue
                    }
                    stats = fresh
                    cache[key] = fresh
                    cacheDirty = true
                }

                sessions += 1
                messages += stats.messages
                input += stats.input
                output += stats.output
                models.formUnion(stats.models)
            }

            guard sessions > 0 else { continue }
            let encoded = entry.dir.lastPathComponent
            results.append(
                ProjectUsage(
                    projectPath: encoded,
                    projectName: projectName(fromEncoded: encoded),
                    sessionCount: sessions,
                    messageCount: messages,
                    inputTokens: input,
                    outputTokens: output,
                    models: models.sorted()
                )
            )
        }

        if cacheDirty { saveCache(cache) }

        results.sort { $0.totalTokens > $1.totalTokens }
        return UsageSummary(
            projects: results,
            totalSessions: results.reduce(0) { $0 + $1.sessionCount },
            totalMessages: results.reduce(0) { $0 + $1.messageCount },
            totalInput: results.reduce(0) { $0 + $1.inputTokens },
            totalOutput: results.reduce(0) { $0 + $1.outputTokens }
        )
    }

    // MARK: - 流式解析

    /// 分块读一个 jsonl，逐行统计。
    ///
    /// **不用 `String(contentsOf:)`。** 单个会话文件可以有几十 MB，
    /// 全量目录接近 1 GB，整份读进内存再 `split` 是这个功能之前根本跑不出结果的原因。
    ///
    /// 分块读的关键细节：块边界几乎必然落在某一行中间，所以每块处理完要把
    /// 残留的尾巴留到下一块开头拼接，否则会漏掉/切坏跨块的那一行。
    static func scanFile(_ url: URL, size: Int64, modified: Date) -> FileUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var messages = 0
        var input = 0
        var output = 0
        var models = Set<String>()
        var carry = Data()

        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            // 预筛：绝大多数行（user 消息、attachment、快照）不含 usage。
            // 在 Data 上做子串查找，避免为每一行构造 String。
            guard line.range(of: Data("\"usage\"".utf8)) != nil else { return }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["message"] as? [String: Any]
            else { return }

            if let model = message["model"] as? String { models.insert(model) }
            guard let usage = message["usage"] as? [String: Any] else { return }

            messages += 1
            input += (usage["input_tokens"] as? Int) ?? 0
            input += (usage["cache_read_input_tokens"] as? Int) ?? 0
            input += (usage["cache_creation_input_tokens"] as? Int) ?? 0
            output += (usage["output_tokens"] as? Int) ?? 0
        }

        let newline = UInt8(ascii: "\n")
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var buffer = carry
            buffer.append(chunk)
            carry = Data()

            var start = buffer.startIndex
            while let index = buffer[start...].firstIndex(of: newline) {
                consume(buffer[start..<index])
                start = buffer.index(after: index)
            }
            // 块尾没换行的部分留给下一块。
            if start < buffer.endIndex {
                carry = Data(buffer[start...])
            }
        }
        consume(carry)

        return FileUsage(
            size: size, modified: modified, messages: messages,
            input: input, output: output, models: models.sorted()
        )
    }

    // MARK: - 缓存

    /// jsonl 是只追加的，同一个文件的 size + mtime 没变就不可能有新数据。
    /// 缓存落盘之后第二次打开是秒开，而不是重扫近 1 GB。
    static func loadCache() -> [String: FileUsage] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: FileUsage].self, from: data)
        else { return [:] }
        return decoded
    }

    static func saveCache(_ cache: [String: FileUsage]) {
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
