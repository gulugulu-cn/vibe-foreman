import AppKit
import Foundation
import HubProbe

/// 在终端里打开项目的方式。
public enum LaunchMode: String, CaseIterable, Sendable {
    case claude
    case claudeSkipPermissions
    case terminal
    case resumeLast
    case resumePick
    case resumeSession
    case finder
    case vscode

    public var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .claudeSkipPermissions: return "Claude Code（跳过权限）"
        case .terminal: return "终端"
        case .resumeLast: return "继续上次会话"
        case .resumePick: return "选择历史会话"
        case .resumeSession: return "恢复此会话"
        case .finder: return "在 Finder 打开"
        case .vscode: return "用 VS Code 打开"
        }
    }

    /// 要在 tmux 窗口里跑的命令。nil 表示只开一个 shell。
    func command(sessionId: String?) -> String? {
        switch self {
        case .claude: return "claude"
        case .claudeSkipPermissions: return "claude --dangerously-skip-permissions"
        case .terminal: return nil
        case .resumeLast: return "claude --continue"
        case .resumePick: return "claude --resume"
        case .resumeSession:
            guard let sessionId else { return "claude --resume" }
            return "claude --resume \(shellQuote(sessionId))"
        case .finder, .vscode: return nil
        }
    }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// 终端派发。
///
/// ## 必须保留的隐性约束：Keychain ACL
///
/// **首次 `tmux new-session` 必须由终端进程执行**，不能由本 app 直接跑。
///
/// 原因：这样 tmux server 的父进程是 iTerm，claude 作为它的子进程才能复用
/// iTerm 在 macOS Keychain 上的 ACL。如果由 app 创建 tmux server，claude
/// 拿不到登录态，用户会莫名其妙地掉线。这是上一版踩过的坑，改写时原样保留。
///
/// 后续的 `new-window` / `send-keys` 是 client 操作，谁跑都行。
public struct TerminalDispatch: Sendable {

    public enum Terminal: String, Sendable {
        case iTerm = "iTerm2"
        case terminal = "Terminal"

        var bundleId: String {
            switch self {
            case .iTerm: return "com.googlecode.iterm2"
            case .terminal: return "com.apple.Terminal"
            }
        }

        /// 磁盘上 `.app` 可能叫什么。
        ///
        /// **`rawValue` 是 AppleScript 名，不是包名。** iTerm2 的 AppleScript
        /// 名叫 `iTerm2`，但包实际是 `/Applications/iTerm.app`（可执行文件才叫
        /// iTerm2）。旧实现拿 rawValue 拼路径去找 `iTerm2.app`，永远找不到，
        /// 于是 `detectTerminal()` 一路降级到 macOS 终端 ——
        /// 实机现象是「重启后第一次开项目弹的是系统终端」：
        /// 平时 hub session 已存在且有客户端连着，走的是 addWindow，
        /// 根本不经过这里；只有开机后第一次建 session 才会暴露。
        var appBundleNames: [String] {
            switch self {
            case .iTerm: return ["iTerm", "iTerm2"]
            case .terminal: return ["Terminal"]
            }
        }

        /// iTerm 用 `-CC` 控制模式，tmux 窗口会呈现为原生 tab。
        var attachCommand: String {
            switch self {
            case .iTerm: return "tmux -CC attach -t hub"
            case .terminal: return "tmux attach -t hub"
            }
        }
    }

    public let sessionName: String
    private let tmux: TmuxProbe

    public init(sessionName: String = "hub", tmux: TmuxProbe = TmuxProbe()) {
        self.sessionName = sessionName
        self.tmux = tmux
    }

    public func detectTerminal() -> Terminal {
        for candidate in [Terminal.iTerm, .terminal] where isInstalled(candidate) {
            return candidate
        }
        return .terminal
    }

    /// 装没装。
    ///
    /// 首选 bundle id 走 LaunchServices —— 用户可能把 app 放在 `~/Applications`、
    /// Setapp 目录、甚至改过名，靠猜路径迟早猜错（上面 `appBundleNames` 注释里
    /// 那个 bug 就是猜错路径的结果）。LaunchServices 查不到时才退回路径探测，
    /// 而且要把两个候选包名都试一遍。
    func isInstalled(_ terminal: Terminal) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleId) != nil {
            return true
        }
        return Self.installedPathCandidates(for: terminal)
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// 路径兜底的候选清单。纯函数，测试盯着它别再退化成只认 `rawValue`。
    static func installedPathCandidates(for terminal: Terminal) -> [String] {
        terminal.appBundleNames.flatMap { name in
            [
                "/Applications/\(name).app",
                NSString(string: "~/Applications/\(name).app").expandingTildeInPath,
                "/System/Applications/Utilities/\(name).app",
            ]
        }
    }

    // MARK: - 打开项目

    @discardableResult
    public func open(
        project name: String,
        path: String,
        mode: LaunchMode,
        sessionId: String? = nil
    ) -> Bool {
        // **每一次派发都记一笔。**
        //
        // 「点了没反应」和「开到了别的目录」这两类故障，在外面看起来都只是
        // "结果不对"，而中间传了什么完全不可见 —— `log show` 对这个 app 是瞎的
        //（ad-hoc 签名，NOTES.md 记过），os.Logger 打了也看不到。
        // 没有这份记录时我只能靠读代码猜 path 怎么会变空，猜了三轮没猜中。
        Self.trace("open mode=\(mode.rawValue) name=\(name) path=\(path.isEmpty ? "<空>" : path)")

        // **目录不存在必须当场拦下，不能让它往下走。**
        //
        // tmux 对不存在的 `-c` 目录**返回 0 并静默回落到家目录** ——
        // 实测 `tmux new-session -c /不存在的路径` exit=0，
        // `pane_current_path` 变成 `/Users/dev`。`open /不存在` 则什么都不做。
        // 两者都不报错。
        //
        // 于是 projects.yaml 里 6 条指向已删除目录的记录，表现成
        // 「Finder 那些全没用」+「Claude 开到家目录」，看起来像右键菜单坏了，
        // 而真正坏的是数据。我为此猜了三轮代码都没猜中 ——
        // **一个静默回落的 API 会把数据问题伪装成功能问题。**
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            Self.trace("拒绝：\(name) 的路径是空的（检查 projects.yaml）")
            return false
        }
        guard exists, isDirectory.boolValue else {
            Self.trace("拒绝：\(name) 的目录不存在 —— \(path)")
            return false
        }

        switch mode {
        case .finder:
            return Shell.run("/usr/bin/open", [path], timeout: 5).succeeded
        case .vscode:
            // code 不一定在 GUI app 的 PATH 里，用 open -a 更稳。
            let direct = Shell.run("/usr/bin/open", ["-a", "Visual Studio Code", path], timeout: 5)
            return direct.succeeded
        default:
            break
        }

        // 起 claude 之前先把项目配置补齐（防污染 deny + 全套 hook）。
        //
        // **这条路必须单独补一次。** app 从岛/主窗口启动项目时**完全不经过**
        // project-menu.sh —— 那个脚本只有 tmux 手动开的路径会走。
        // 漏了这里的话，凡是从 Hub 界面点开的项目一个都没被检查过，
        // 而那正是最常用的入口。
        ensureProjectConfig(path)

        let inner = mode.command(sessionId: sessionId)

        if hubSessionExists() {
            return addWindow(name: name, path: path, command: inner)
        }
        return createSession(name: name, path: path, command: inner)
    }

    /// 派发日志。
    ///
    /// 写文件而不是 `os.Logger`：本机实测 `log show` 完全看不到这个 app 的输出
    /// （多半和 ad-hoc 签名有关），同 `SessionWatchdog` 的心跳。
    /// **一个看不见的仪表比没有仪表更糟** —— 我拿它做过诊断，得出了错误结论。
    static func trace(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-hub/launch.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// 补齐项目的 `.claude/settings.json`（防污染 deny + 全套 hook）。
    ///
    /// 脚本自己是幂等的、也自己兜底不阻断，所以这里失败了什么都不用做 ——
    /// 让项目起不来的代价远大于少一次配置检查。
    private func ensureProjectConfig(_ path: String) {
        guard let script = Self.locateScript("ensure-project-config.sh") else { return }
        _ = Shell.run("/bin/bash", [script, path], timeout: 10)
    }

    /// 找 hub 的脚本目录。
    ///
    /// **不能靠 PATH 或相对路径**：Hub 是 GUI app，从 launchd 起，
    /// 工作目录和 PATH 都不是终端里那一套（`StallJudge.locateClaude` 同理）。
    static func locateScript(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Documents/code/claude-hub/scripts/\(name)",
            "\(home)/.local/share/claude-hub/scripts/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func hubSessionExists() -> Bool {
        Shell.run(tmux.tmuxPath, ["has-session", "-t", sessionName], timeout: 3).succeeded
    }

    /// 第一次创建：**必须**让终端来跑，见类型注释里的 Keychain 说明。
    private func createSession(name: String, path: String, command: String?) -> Bool {
        let terminal = detectTerminal()
        ensureRunning(terminal)

        var create = "tmux new-session -d -s \(shellQuote(sessionName))"
            + " -n \(shellQuote(name)) -c \(shellQuote(path))"
        if let command {
            create += " \(shellQuote(command))"
        }
        return runInTerminal("\(create) && \(terminal.attachCommand)", terminal: terminal)
    }

    /// session 已存在：直接加窗口，这是 client 操作，app 自己跑没问题。
    private func addWindow(name: String, path: String, command: String?) -> Bool {
        // 注意 flag 必须全部排在 shell-command 之前，否则 tmux 会把 flag
        // 当成命令的一部分。
        var args = [
            "new-window", "-t", sessionName, "-n", name, "-c", path,
            "-P", "-F", "#{window_id}",
        ]
        if let command { args.append(command) }

        let result = Shell.run(tmux.tmuxPath, args, timeout: 5)
        guard result.succeeded else { return false }

        let windowId = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // 没有客户端连着的话，新窗口只是后台多了一个，用户什么都看不到。
        let clients = Shell.run(tmux.tmuxPath, ["list-clients", "-t", sessionName], timeout: 3)
        if clients.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let terminal = detectTerminal()
            ensureRunning(terminal)
            return runInTerminal(terminal.attachCommand, terminal: terminal)
        }

        // 有客户端：iTerm 不会自动前置新 tab，得主动切过去。
        if !windowId.isEmpty {
            Shell.run(tmux.tmuxPath, ["select-window", "-t", windowId], timeout: 3)
        }
        Shell.osascript(#"tell application "iTerm2" to activate"#, timeout: 4)
        return true
    }

    // MARK: - 终端控制

    /// 确保终端在跑且 AppleEvent 接收器就绪。
    ///
    /// 冷启动的 app 会有一段时间接受不了 AppleEvent，这时候发脚本会静默失败。
    /// 所以要轮询探测 —— 用 `tell app to return id`，它不创建窗口、无副作用。
    private func ensureRunning(_ terminal: Terminal) {
        // 用 bundle id 判活，不用 `pgrep -x <名字>`：
        // ① 进程名和 AppleScript 名不一定一致；
        // ② macOS 的 pgrep **默认把自己的祖先排除在匹配之外**（要 `-a` 才算上），
        //    所以从 iTerm 里跑起来的 hubctl/hubprobe 问「iTerm 在跑吗」永远答否。
        if !NSRunningApplication
            .runningApplications(withBundleIdentifier: terminal.bundleId).isEmpty {
            return
        }

        // -g：不抢焦点，稍后让 AppleScript 的 activate 来抢，
        // 避免冷启动期间焦点反复跳。
        Shell.run("/usr/bin/open", ["-g", "-b", terminal.bundleId], timeout: 5)

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let probe = Shell.osascript(
                "tell application \"\(terminal.rawValue)\" to return id", timeout: 3
            )
            if probe.succeeded,
               !probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            usleep(150_000)
        }
    }

    private func runInTerminal(_ command: String, terminal: Terminal) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        switch terminal {
        case .iTerm:
            script = """
            tell application "iTerm2"
                activate
                if (count of windows) = 0 then
                    set w to (create window with default profile)
                    tell current session of current tab of w
                        write text "\(escaped)"
                    end tell
                else
                    tell current window
                        create tab with default profile
                        delay 0.3
                        tell current session of current tab
                            write text "\(escaped)"
                        end tell
                    end tell
                end if
            end tell
            """
        case .terminal:
            script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        }
        return Shell.osascript(script, timeout: 15).succeeded
    }
}
