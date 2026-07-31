import Foundation
import HubCore
import HubProbe
import HubProjects

/// 演示模式：用一组合成的会话和项目跑起来。
///
/// 用途是**截图**。真实数据里全是内部项目名、分支名和 commit 标题，
/// 不能对外；而且要等真实会话凑出"1 个在等你 + 2 个在忙 + 1 个跑命令 + 几个闲着"
/// 这种展示效果好的组合，纯靠运气。
///
/// 合成数据同时解决两件事：不泄露，且每次截图**完全一致**——
/// 换一版 UI 之后重截，图与图之间可以直接比对。
///
/// 用法：
///
///     HUB_DEMO=1 HUB_ISLAND_STATE=hover "/Applications/Claude Hub.app/Contents/MacOS/ClaudeHub"
///
/// 实现上是往临时目录写一批 `sessions/<PID>.json` 再让 reader 指过去，
/// 而不是在 store 里塞假数据 —— 这样**走的是和生产完全一样的解析路径**，
/// 截出来的图能反映真实的渲染结果，包括解析出错时的样子。
public enum DemoFixtures {

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["HUB_DEMO"] == "1"
    }

    /// 合成会话。名字刻意写成任何团队都可能有的通用任务。
    private struct Fixture {
        let pid: pid_t
        let name: String
        let project: String
        let status: String
        let waitingFor: String?
        let ageMinutes: Int
    }

    private static let fixtures: [Fixture] = [
        .init(pid: 40101, name: "checkout-refund-flow", project: "storefront",
              status: "waiting", waitingFor: "input needed", ageMinutes: 2),
        .init(pid: 40102, name: "search-ranking-tuning", project: "api-gateway",
              status: "busy", waitingFor: nil, ageMinutes: 1),
        .init(pid: 40103, name: "invoice-pdf-export", project: "billing-service",
              status: "busy", waitingFor: nil, ageMinutes: 4),
        .init(pid: 40104, name: "db-migration-rollback", project: "billing-service",
              status: "shell", waitingFor: nil, ageMinutes: 7),
        .init(pid: 40105, name: "onboarding-copy-review", project: "marketing-site",
              status: "idle", waitingFor: nil, ageMinutes: 26),
        .init(pid: 40106, name: "mobile-nav-a11y", project: "design-system",
              status: "idle", waitingFor: nil, ageMinutes: 41),
        .init(pid: 40107, name: "webhook-retry-backoff", project: "api-gateway",
              status: "idle", waitingFor: nil, ageMinutes: 63),
    ]

    /// 演示项目。带分支名和提交记录 —— **分支、变更数、最近提交正是要展示的功能**，
    /// 用空目录跑出来那几栏全是空的，截图等于什么都没展示。
    private struct DemoProject {
        let name: String
        let branch: String
        let commits: [String]
        /// 未提交的文件数，对应界面上的 `N△`。
        let dirtyFiles: Int
    }

    private static let demoProjects: [DemoProject] = [
        .init(name: "storefront", branch: "feat/checkout-refund",
              commits: ["feat(checkout): 退款走独立状态机",
                        "fix(cart): 优惠券叠加时总价算错"], dirtyFiles: 3),
        .init(name: "api-gateway", branch: "feat/search-ranking",
              commits: ["perf(search): 召回阶段加一层倒排缓存",
                        "feat(search): 支持按更新时间加权"], dirtyFiles: 1),
        .init(name: "billing-service", branch: "release/2026-08",
              commits: ["feat(invoice): PDF 导出支持多币种",
                        "chore(db): 补上 orders 的复合索引"], dirtyFiles: 0),
        .init(name: "marketing-site", branch: "main",
              commits: ["docs: 重写首屏文案"], dirtyFiles: 2),
        .init(name: "design-system", branch: "main",
              commits: ["feat(a11y): 导航补齐键盘焦点顺序"], dirtyFiles: 0),
        .init(name: "notification-worker", branch: "main", commits: ["init"], dirtyFiles: 0),
        .init(name: "analytics-pipeline", branch: "main", commits: ["init"], dirtyFiles: 0),
        .init(name: "admin-console", branch: "main", commits: ["init"], dirtyFiles: 0),
        .init(name: "mobile-app", branch: "main", commits: ["init"], dirtyFiles: 0),
        .init(name: "docs-site", branch: "main", commits: ["init"], dirtyFiles: 0),
    ]

    /// 演示工作区。**不放临时目录** —— 界面上会原样显示 cwd，
    /// `/var/folders/bw/f9gvdbfn…` 这种路径在截图里既难看又泄露本机的目录哈希。
    /// 放一个语义清楚、截完能整个删掉的位置。
    public static var workspaceRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/claude-hub-demo", isDirectory: true)
    }

    /// 演示用的根目录。每次启动重建，退出后留着也无所谓（在临时目录里）。
    public static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-hub-demo", isDirectory: true)
    }

    public static var sessionsDirectory: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public static var projectsYAML: URL {
        root.appendingPathComponent("projects.yaml")
    }

    /// 把合成数据写到磁盘。必须在 store 首次读取之前调用。
    public static func materialize() {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let now = Date().timeIntervalSince1970 * 1000
        let workspace = workspaceRoot
        makeGitWorkspaces(at: workspace)

        for fixture in fixtures {
            let cwd = workspace.appendingPathComponent(fixture.project).path
            let updated = now - Double(fixture.ageMinutes) * 60_000
            var payload: [String: Any] = [
                "pid": fixture.pid,
                "sessionId": "demo-\(fixture.pid)-0000-4000-8000-000000000000",
                "cwd": cwd,
                "name": fixture.name,
                "nameSource": "derived",
                "status": fixture.status,
                "kind": "interactive",
                "entrypoint": "cli",
                "version": "2.1.220",
                // 启动时间给得久一点，"运行 N 小时"读起来才像真的。
                "startedAt": now - Double(fixture.ageMinutes + 180) * 60_000,
                "updatedAt": updated,
                "statusUpdatedAt": updated,
            ]
            if let waitingFor = fixture.waitingFor { payload["waitingFor"] = waitingFor }

            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            try? data.write(
                to: sessionsDirectory.appendingPathComponent("\(fixture.pid).json")
            )
        }

        var yaml = "# 演示数据\nprojects:\n"
        for project in demoProjects {
            yaml += "  - name: \(project.name)\n"
            yaml += "    path: \(workspace.appendingPathComponent(project.name).path)\n"
        }
        try? yaml.write(to: projectsYAML, atomically: true, encoding: .utf8)
    }

    /// 建一批真的 git 仓库：有分支、有提交历史、有未提交的改动。
    ///
    /// 用真仓库而不是伪造 `GitInfo`，理由和会话数据一样：**走生产的同一条路径**。
    /// 界面上的分支名、`N△`、提交列表都是 `git` 真跑出来的，
    /// 截图反映的就是用户会看到的东西。
    private static func makeGitWorkspaces(at root: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: root)

        for project in demoProjects {
            let dir = root.appendingPathComponent(project.name, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            run("/usr/bin/git", ["init", "-q", "-b", project.branch], in: dir)
            // 用仓库级配置，绝不碰用户的全局 git 身份。
            run("/usr/bin/git", ["config", "user.name", "Demo"], in: dir)
            run("/usr/bin/git", ["config", "user.email", "demo@example.com"], in: dir)

            for (index, message) in project.commits.enumerated() {
                let file = dir.appendingPathComponent("src-\(index).txt")
                try? "demo \(index)\n".write(to: file, atomically: true, encoding: .utf8)
                run("/usr/bin/git", ["add", "-A"], in: dir)
                // 把提交时间往前推。不推的话界面上全是"3 seconds ago"——
                // 仓库是刚建的，一眼假。倒序：越新的提交越靠近现在。
                let hoursAgo = (project.commits.count - index) * 5 - 2
                let date = Date().addingTimeInterval(-Double(hoursAgo) * 3600)
                let stamp = ISO8601DateFormatter().string(from: date)
                run(
                    "/usr/bin/git", ["commit", "-q", "-m", message], in: dir,
                    environment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp]
                )
            }

            for index in 0..<project.dirtyFiles {
                let file = dir.appendingPathComponent("wip-\(index).txt")
                try? "未提交\n".write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func run(
        _ tool: String,
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = [:]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                _, new in new
            }
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// 演示用的终端定位。
    ///
    /// 真实使用时这一栏显示 `iTerm · <tab 名>`，是这个工具的核心能力之一；
    /// 演示会话不在任何终端里，如实解析会显示"未定位到终端"——
    /// 那会让展示图**低估**产品的实际表现。这里给出和真实格式一致的值。
    public static func terminalLabels() -> [String: String] {
        var labels: [String: String] = [:]
        for fixture in fixtures {
            labels["demo-\(fixture.pid)-0000-4000-8000-000000000000"] =
                "iTerm · \(fixture.name)  ·  tmux · hub:\(fixture.project)"
        }
        return labels
    }

    /// 截完图把演示工作区删干净。
    public static func cleanUp() {
        try? FileManager.default.removeItem(at: workspaceRoot)
        try? FileManager.default.removeItem(at: root)
    }

    /// 演示用的滞留判定结果。
    ///
    /// 滞留提醒是**时间驱动**的：真实触发要等会话安静三分钟以上，
    /// 而截图和布局核对需要它立刻出现且每次一致。合成一组覆盖全部五类原因，
    /// 顺便当成"五种图标能不能一眼区分"的目视检查。
    public static func stallFindings(now: Date = Date()) -> [StallFinding] {
        func id(_ pid: pid_t) -> String { "demo-\(pid)-0000-4000-8000-000000000000" }
        return [
            StallFinding(
                sessionId: id(40103),
                reason: .interrupted("API Error: Connection closed mid-response."),
                grade: .high, since: now.addingTimeInterval(-260)
            ),
            StallFinding(
                sessionId: id(40101),
                reason: .askedQuestion("需要我把这两个提交推送到 live 吗？"),
                grade: .high, since: now.addingTimeInterval(-180)
            ),
            StallFinding(
                sessionId: id(40104),
                reason: .unfinishedTasks(pending: 1, inProgress: 1, next: "阶段三：只读面板"),
                grade: .high, since: now.addingTimeInterval(-900)
            ),
            StallFinding(
                sessionId: id(40105),
                reason: .finishedAwaitingReview(summary: "四项优化完成并提交", workedFor: 1794),
                grade: .high, since: now.addingTimeInterval(-420)
            ),
        ]
    }

    /// 演示用的应答请求。选项取自实测里 AI 真实返回的那一组。
    public static func answerRequest() -> AnswerRequest {
        AnswerRequest(
            sessionId: "demo-40101-0000-4000-8000-000000000000",
            sessionName: "checkout-refund-flow",
            question: "两个提交已在预览主题验证过，需要我把它们精准推送到 live 吗？",
            options: ["是，请推送", "否，先检查", "稍后再推"],
            target: "iTerm · checkout-refund-flow"
        )
    }

    /// 演示模式下这些进程当然不存在，`kill(pid,0)` 会把它们全过滤掉。
    /// 所以演示模式要关掉存活检查 —— 这也是 reader 需要这个开关的唯一理由。
    public static func makeReader() -> ClaudeSessionReader {
        ClaudeSessionReader(directory: sessionsDirectory, requiresLiveProcess: false)
    }
}
