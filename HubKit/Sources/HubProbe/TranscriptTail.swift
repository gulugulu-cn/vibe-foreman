import Foundation

/// 一个会话 transcript 尾部的摘要。
///
/// 只关心"这个会话最后停在什么状态"，不关心历史。
public struct TranscriptTail: Sendable, Equatable {
    /// 最后一条 assistant 消息的正文（多个 text block 拼起来）。
    public let lastAssistantText: String?

    /// **最后一条 assistant 消息是 API 错误。**
    ///
    /// 这就是"这一轮死在半路上"的判据。取的是最后一条，所以错误后面
    /// 只要还有正常回复，这里就是 false —— 那说明重试成功了，不该报警。
    public let endedWithApiError: Bool

    /// 最后一条**真实**用户消息的时刻。
    ///
    /// 注意不是所有 `type == "user"` 的行：transcript 里绝大多数 user 行是
    /// 工具结果回填（本机实测某会话 41 条真实消息对 1645 条工具结果）。
    /// 不区分的话"用户回应过了吗"这个判据会完全失效。
    public let lastUserMessageAt: Date?

    /// 尾部最后一条有时间戳的记录。
    public let lastActivityAt: Date?

    public init(
        lastAssistantText: String?,
        endedWithApiError: Bool,
        lastUserMessageAt: Date?,
        lastActivityAt: Date?
    ) {
        self.lastAssistantText = lastAssistantText
        self.endedWithApiError = endedWithApiError
        self.lastUserMessageAt = lastUserMessageAt
        self.lastActivityAt = lastActivityAt
    }
}

/// 读 `~/.claude/projects/<编码后的 cwd>/<sessionId>.jsonl` 的尾部。
///
/// ## 为什么只读尾部
///
/// 这些 jsonl 是只追加的，单个能到几十 MB，全目录本机实测 945 MB。
/// `UsageStats` 早期版本用 `String(contentsOf:)` 整个读进内存，
/// 结果用量页面永远转不出来（见 NOTES.md）。同样的错误不能犯第二次 ——
/// 我们只要最后几条记录，读最后 64 KB 就够。
///
/// ## 为什么不用 hook 传来的 transcriptPath
///
/// `HookEvent.transcriptPath` 只在 Stop / Notification 事件里才有。
/// 而滞留检测是**周期性地扫所有 idle 会话**，大多数时候手上根本没有事件，
/// 所以必须能独立地从 (cwd, sessionId) 定位到文件。
public struct TranscriptReader: Sendable {

    /// `~/.claude/projects`。
    public let projectsDirectory: URL

    /// 尾部窗口。找不到 assistant 消息时会翻倍重试，见 `maxTailBytes`。
    public let tailBytes: Int

    /// 重试的上限。超过这个还找不到就放弃 —— 再大就违背"只读尾部"的初衷了。
    private static let maxTailBytes = 1 << 20

    public init(projectsDirectory: URL? = nil, tailBytes: Int = 64 << 10) {
        self.projectsDirectory = projectsDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        self.tailBytes = tailBytes
    }

    // MARK: - 定位

    /// cwd 的目录名编码：**非字母数字一律换成 `-`**。
    ///
    /// 本机 30 个真实样本全部符合，包括
    /// `/Users/dev/Library/Application Support/@agentx/desktop`
    /// → `-Users-dev-Library-Application-Support--agentx-desktop`
    /// （空格和 `@` 都变成了 `-`，`/@` 连着两个所以出现 `--`）。
    ///
    /// **但样本里一个带 `.` 或 `_` 的路径都没有**，所以"点要不要保留"这条
    /// 区分不出来。因此这个函数只作为快路径，命中不了一律走 `locate` 的兜底。
    static func encode(cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// 定位 transcript 文件。
    ///
    /// 先按编码规则直接拼（快，一次 stat）；拼不中就在 projects 下按
    /// **sessionId 精确匹配文件名**兜底。sessionId 是 UUID、全局唯一，
    /// 所以兜底是精确的 —— 这比去猜编码规则可靠得多。
    public func locate(cwd: String, sessionId: String) -> URL? {
        let fm = FileManager.default

        let fast = projectsDirectory
            .appendingPathComponent(Self.encode(cwd: cwd), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: fast.path) { return fast }

        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - 读取

    public func read(cwd: String, sessionId: String) -> TranscriptTail? {
        guard let url = locate(cwd: cwd, sessionId: sessionId) else { return nil }
        return read(url: url)
    }

    public func read(url: URL) -> TranscriptTail? {
        var window = tailBytes
        while true {
            guard let lines = Self.tailLines(of: url, bytes: window) else { return nil }
            let tail = Self.parse(lines)

            // 尾部窗口里一条 assistant 都没有，多半是被一个超大的工具结果撑开了。
            // 翻倍再试，但有上限 —— 再大就违背"只读尾部"的初衷。
            if tail.lastAssistantText == nil, !tail.endedWithApiError,
               window < Self.maxTailBytes {
                window *= 2
                continue
            }
            return tail
        }
    }

    /// 从文件尾部读若干字节并切成行。
    ///
    /// 不是从 0 读起时，**第一行必然是残缺的**（窗口边界大概率落在某行中间），
    /// 必须丢掉，否则 JSON 解析会失败或者更糟 —— 解析出半截内容。
    static func tailLines(of url: URL, bytes: Int) -> [Data]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    static func parse(_ lines: [Data]) -> TranscriptTail {
        var lastAssistantText: String?
        var endedWithApiError = false
        var lastUserMessageAt: Date?
        var lastActivityAt: Date?

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let entry = object as? [String: Any],
                  let type = entry["type"] as? String
            else { continue }

            if let stamp = timestamp(entry["timestamp"]) { lastActivityAt = stamp }

            switch type {
            case "assistant":
                // 逐条覆盖，循环结束时留下的就是最后一条。
                // API 错误标记也跟着覆盖 —— 错误之后若有正常回复，这里自然变回 false。
                lastAssistantText = text(in: entry)
                endedWithApiError = entry["isApiErrorMessage"] as? Bool ?? false

            case "user":
                // 工具结果回填和系统 meta 都长成 user，必须排除，见 TranscriptTail 的说明。
                guard entry["toolUseResult"] == nil,
                      !(entry["isMeta"] as? Bool ?? false)
                else { continue }
                if let stamp = timestamp(entry["timestamp"]) { lastUserMessageAt = stamp }

            default:
                continue
            }
        }

        return TranscriptTail(
            lastAssistantText: lastAssistantText,
            endedWithApiError: endedWithApiError,
            lastUserMessageAt: lastUserMessageAt,
            lastActivityAt: lastActivityAt
        )
    }

    /// 取 assistant 消息里的纯文本。`content` 是 block 数组，
    /// 只拼 `type == "text"` 的那些，工具调用块跳过。
    private static func text(in entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return nil }

        let pieces = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// transcript 的时间戳是带毫秒的 ISO8601（`2026-07-27T06:29:44.882Z`）。
    ///
    /// 用 `Date.ISO8601FormatStyle` 而不是 `ISO8601DateFormatter`：后者是个 class、
    /// 不满足 `Sendable`，在 Swift 6 严格并发下连 `static let` 都建不出来
    /// （而这里每次解析都新建一个 formatter 是不可接受的 —— 一次尾部解析要跑几百行）。
    /// `ISO8601FormatStyle` 是值类型，天然并发安全。
    ///
    /// 小数秒要显式声明：带小数和不带小数是两个不同的 style，互相不认。
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    private static func timestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return (try? isoFractional.parse(string)) ?? (try? isoPlain.parse(string))
    }
}
