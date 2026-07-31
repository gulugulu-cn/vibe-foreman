import Foundation

/// 一个会话的任务清单快照。
public struct TaskSnapshot: Sendable, Equatable {
    public let pending: Int
    public let inProgress: Int
    public let completed: Int

    /// 下一件该干的事的标题。优先取 `in_progress`，没有再取第一条 `pending`。
    ///
    /// 提醒文案里"还差：阶段三 admin 网关面板"比"还有 2 项未完成"有用得多 ——
    /// 后者还得跳过去才知道是什么。
    public let nextSubject: String?

    /// 任务目录的最后修改时刻。用来判断"用户是不是已经动过了"。
    public let modifiedAt: Date?

    public var unfinished: Int { pending + inProgress }
    public var total: Int { pending + inProgress + completed }
    public var isEmpty: Bool { total == 0 }

    public init(
        pending: Int, inProgress: Int, completed: Int,
        nextSubject: String? = nil, modifiedAt: Date? = nil
    ) {
        self.pending = pending
        self.inProgress = inProgress
        self.completed = completed
        self.nextSubject = nextSubject
        self.modifiedAt = modifiedAt
    }
}

/// 读 `~/.claude/tasks/<会话目录>/<id>.json` —— Claude Code 自己维护的任务清单。
///
/// 这是"这个会话还有后续没做完"的**确定性**判据，不用 AI、不花额度。
/// 本机对过账：会话 `gateway-config-management` 读出
/// `{completed: 2, in_progress: 1, pending: 1}`，
/// 与 Claude 自己界面上显示的 `4 tasks (2 done, 1 in progress, 1 open)` 完全一致。
///
/// 注意**不是每个会话都有**：实测 7 个会话里 1 个有清单、4 个目录在但是空的、
/// 2 个连目录都没有。所以这个探针命中率有限，测不到的交给 AI 那层兜底。
public struct TaskStateReader: Sendable {

    public let tasksDirectory: URL

    public init(tasksDirectory: URL? = nil) {
        self.tasksDirectory = tasksDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/tasks", isDirectory: true)
    }

    /// 会话目录有两种历史命名，都要认：
    /// - `session-<sessionId 前 8 位>`（当前形态）
    /// - `<完整 sessionId>`（旧形态，本机仍有残留）
    func candidateDirectories(for sessionId: String) -> [URL] {
        var result: [URL] = []
        if sessionId.count >= 8 {
            result.append(
                tasksDirectory.appendingPathComponent(
                    "session-\(sessionId.prefix(8))", isDirectory: true
                )
            )
        }
        result.append(tasksDirectory.appendingPathComponent(sessionId, isDirectory: true))
        return result
    }

    public func read(sessionId: String) -> TaskSnapshot? {
        let fm = FileManager.default
        guard let dir = candidateDirectories(for: sessionId).first(where: {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }) else { return nil }

        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        var pending = 0, inProgress = 0, completed = 0
        var openTasks: [(order: Int, subject: String, running: Bool)] = []

        for file in entries where file.pathExtension == "json" {
            // 目录里混着 .lock 和 .highwatermark。`.skipsHiddenFiles` 已经滤掉了它们
            // （都是点开头），扩展名判断是第二道保险。
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let task = object as? [String: Any],
                  let status = task["status"] as? String
            else {
                // **单个文件坏掉不能让整个目录失效。** 任务清单是边跑边写的，
                // 撞上正在写入的半截 json 完全正常，跳过它继续读其余的。
                continue
            }

            let subject = (task["subject"] as? String) ?? ""
            // 文件名是 "7.json"、"10.json"，按数值排序才是任务的真实顺序；
            // 按字符串排的话 "10" 会排到 "7" 前面。
            let order = Int(file.deletingPathExtension().lastPathComponent) ?? Int.max

            switch status {
            case "completed": completed += 1
            case "in_progress":
                inProgress += 1
                openTasks.append((order, subject, true))
            default:
                pending += 1
                openTasks.append((order, subject, false))
            }
        }

        // 正在做的优先；同类按任务编号。
        let next = openTasks
            .sorted { lhs, rhs in
                if lhs.running != rhs.running { return lhs.running }
                return lhs.order < rhs.order
            }
            .first
            .map(\.subject)
            .flatMap { $0.isEmpty ? nil : $0 }

        let modified = (try? fm.attributesOfItem(atPath: dir.path)[.modificationDate]) as? Date

        return TaskSnapshot(
            pending: pending, inProgress: inProgress, completed: completed,
            nextSubject: next, modifiedAt: modified
        )
    }
}
