import Foundation
import HubCore
import HubJump
import HubProbe

/// 往某个会话所在的终端发一行文本 —— 让用户不用跳过去就能回答 AI 的提问。
///
/// # 这是整个滞留提醒里唯一不可逆的动作
///
/// 发出去的一行会被那头的 Claude 当成用户输入执行。用户实拍的例子里，
/// 那个"是"意味着**真往 Shopify live 推代码**。所以这里的每一条护栏都不是
/// 防御性编程的客套，是必须的：
///
/// 1. **发送前重新读一次会话状态。** 中途变 `busy` 说明用户已经自己在那边
///    动手了，这时候插一行进去会打断他 —— 取消并如实告诉他，绝不硬发。
/// 2. **只发一行纯文本 + 回车。** 不发控制字符、不发多行、不发转义序列。
///    多行会被当成多次输入，控制字符能触发终端自己的快捷键。
/// 3. **绑定只走 PID 祖先链**（复用 `JumpEngine.bind` / `TmuxProbe.bindPanes`）。
///    **绝不用窗口名字符串匹配** —— 那是这个项目一开始就废掉的做法，
///    tmux 的 `automatic-rename` 会把窗口名改成前台进程名（实测出现过
///    窗口名变成 `2.1.173`，那是 claude 的版本号）。发错窗口比不发严重得多。
/// 4. **绑定失败就退化成跳转**，不猜、不试探。
/// 5. **每次发送都留痕**，可追溯。
///
/// UI 那一侧还有第六条：点了按钮**不直接发**，先显示"将发送到 X：内容"
/// 让用户确认一次。见 `AnswerContent`。
@MainActor
public struct TerminalReply {

    public enum Outcome: Equatable, Sendable, Error {
        /// 发出去了，附上人能看懂的目标位置。
        case sent(target: String)
        /// 会话在这期间开始干活了 —— 用户自己在那边操作，不该插话。
        case sessionBecameBusy
        /// 定位不到终端。调用方应该退化成"跳转过去"。
        case notLocated
        /// 内容不合法（空、多行、含控制字符）。
        case rejected(String)
        case failed(String)
    }

    private let reader: ClaudeSessionReader
    private let tmux: TmuxProbe
    private let iterm: ITermLocator

    public init(
        reader: ClaudeSessionReader = ClaudeSessionReader(),
        tmux: TmuxProbe = TmuxProbe(),
        iterm: ITermLocator = ITermLocator()
    ) {
        self.reader = reader
        self.tmux = tmux
        self.iterm = iterm
    }

    /// 校验并规范化要发送的内容。
    ///
    /// 只接受**单行、无控制字符**的短文本。这是护栏②，
    /// 也是唯一一处纯函数，所以单独拿出来给测试用。
    public static func sanitize(_ raw: String) -> Result<String, Outcome> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.rejected("内容为空")) }
        guard trimmed.count <= 200 else { return .failure(.rejected("内容过长")) }

        // 换行会被终端当成"再敲一次回车"，等于凭空多发了一条输入。
        guard !trimmed.contains(where: { $0.isNewline }) else {
            return .failure(.rejected("只能发一行"))
        }
        // 控制字符（含 ESC）能触发终端自己的快捷键甚至改变终端模式。
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            return .failure(.rejected("含控制字符"))
        }
        return .success(trimmed)
    }

    /// 权限对话框能接受的按键。**白名单而不是任意字符串** ——
    /// 这条链路绕过了 `sanitize` 的控制字符检查（Esc 本身就是控制字符），
    /// 所以能发什么必须在类型层面钉死。
    public enum DialogKey: Equatable, Sendable {
        /// 数字选项（Claude Code 的权限框按数字直接选中）。
        case digit(Int)
        /// Esc = 取消 / 拒绝，所有对话框通用。
        case escape

        var tmuxKey: String {
            switch self {
            case .digit(let n): String(n)
            case .escape: "Escape"
            }
        }

        var rawText: String {
            switch self {
            case .digit(let n): String(n)
            case .escape: String(UnicodeScalar(27))
            }
        }

        public var label: String {
            switch self {
            case .digit(let n): "按键 \(n)"
            case .escape: "Esc"
            }
        }
    }

    /// 往权限对话框发一个裸按键（不带回车）。
    ///
    /// 护栏与 `send` 相同：重读状态（变 busy = 用户已经自己答了，取消）、
    /// PID 祖先链定位、定位不到就退化、留痕。
    public func press(_ key: DialogKey, sessionId: String) async -> Outcome {
        let reader = self.reader
        let tmux = self.tmux
        let iterm = self.iterm

        return await Task.detached(priority: .userInitiated) {
            Self.performPress(
                key: key, sessionId: sessionId,
                reader: reader, tmux: tmux, iterm: iterm
            )
        }.value
    }

    nonisolated static func performPress(
        key: DialogKey,
        sessionId: String,
        reader: ClaudeSessionReader,
        tmux: TmuxProbe,
        iterm: ITermLocator
    ) -> Outcome {
        let sessions = reader.readAll()
        guard let session = sessions.first(where: { $0.sessionId == sessionId }) else {
            return .failed("会话已经不在了")
        }
        // 会话在干活 = 对话框已经被答掉了。这时候再发按键会打进输入框。
        guard !session.status.isWorking else { return .sessionBecameBusy }

        let tree = ProcessTree.snapshot()

        if let pane = tmux.bindPanes(to: [session.pid], tree: tree)[session.pid] {
            let result = Shell.run(
                tmux.tmuxPath,
                ["send-keys", "-t", pane.paneId, key.tmuxKey],
                timeout: 5
            )
            guard result.succeeded else {
                return .failed("tmux send-keys 失败：\(result.stderr)")
            }
            let target = "tmux · \(pane.sessionName):\(pane.windowName)"
            log(text: key.label, sessionId: sessionId, target: target)
            return .sent(target: target)
        }

        if ITermLocator.isRunning() {
            let terms = iterm.snapshot()
            let bound = JumpEngine.bind(
                itermSessions: terms, claudeSessions: [session], tree: tree
            )
            if let uuid = bound[sessionId] {
                // Esc 用 character id 27 拼进 AppleScript；`newline NO` 保证不带回车。
                let payload: String
                switch key {
                case .digit(let n): payload = "\"\(n)\""
                case .escape: payload = "(character id 27)"
                }
                let script = """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if id of s is "\(uuid)" then
                                    tell s to write text \(payload) newline NO
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "missing"
                """
                let result = Shell.osascript(script, timeout: 8)
                guard result.succeeded, result.stdout.contains("ok")
                else { return .failed("iTerm 写入失败：\(result.stderr)") }

                let name = terms.first { $0.sessionUUID == uuid }?.name ?? ""
                let target = name.isEmpty ? "iTerm" : "iTerm · \(name)"
                log(text: key.label, sessionId: sessionId, target: target)
                return .sent(target: target)
            }
        }

        return .notLocated
    }

    /// 发送。**必须在后台线程调用它的 `perform`**，这里只做校验和取快照。
    public func send(text: String, to sessionId: String) async -> Outcome {
        let sanitized: String
        switch Self.sanitize(text) {
        case .success(let value): sanitized = value
        case .failure(let outcome): return outcome
        }

        let reader = self.reader
        let tmux = self.tmux
        let iterm = self.iterm

        return await Task.detached(priority: .userInitiated) {
            Self.perform(
                text: sanitized, sessionId: sessionId,
                reader: reader, tmux: tmux, iterm: iterm
            )
        }.value
    }

    /// 真正的发送。跑在后台线程 —— AppleScript 和 tmux 都是跨进程调用。
    nonisolated static func perform(
        text: String,
        sessionId: String,
        reader: ClaudeSessionReader,
        tmux: TmuxProbe,
        iterm: ITermLocator
    ) -> Outcome {
        // 护栏①：**重新读一次**，不用 UI 上那份可能已经过期几秒的快照。
        let sessions = reader.readAll()
        guard let session = sessions.first(where: { $0.sessionId == sessionId }) else {
            return .failed("会话已经不在了")
        }
        guard !session.status.isWorking else { return .sessionBecameBusy }

        let tree = ProcessTree.snapshot()

        // 护栏③：优先 tmux —— send-keys 是直接投递到 pane，
        // 不需要把窗口切到前台，也就不会打断用户当前在做的事。
        if let pane = tmux.bindPanes(to: [session.pid], tree: tree)[session.pid] {
            let result = Shell.run(
                tmux.tmuxPath,
                ["send-keys", "-t", pane.paneId, text, "Enter"],
                timeout: 5
            )
            guard result.succeeded else {
                return .failed("tmux send-keys 失败：\(result.stderr)")
            }
            let target = "tmux · \(pane.sessionName):\(pane.windowName)"
            log(text: text, sessionId: sessionId, target: target)
            return .sent(target: target)
        }

        // 退而求其次：iTerm。`write text` 只对绑定到的那个 session 生效，
        // 不 activate 整个 app —— 同样不抢用户的焦点。
        if ITermLocator.isRunning() {
            let terms = iterm.snapshot()
            let bound = JumpEngine.bind(
                itermSessions: terms, claudeSessions: [session], tree: tree
            )
            if let uuid = bound[sessionId] {
                let escaped = text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let script = """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if id of s is "\(uuid)" then
                                    tell s to write text "\(escaped)"
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "missing"
                """
                let result = Shell.osascript(script, timeout: 8)
                guard result.succeeded,
                      result.stdout.contains("ok")
                else { return .failed("iTerm 写入失败：\(result.stderr)") }

                let name = terms.first { $0.sessionUUID == uuid }?.name ?? ""
                let target = name.isEmpty ? "iTerm" : "iTerm · \(name)"
                log(text: text, sessionId: sessionId, target: target)
                return .sent(target: target)
            }
        }

        // 护栏④：定位不到就不发。调用方退化成跳转。
        return .notLocated
    }

    /// 人能看懂的目标位置。**发送预览要显示它** ——
    /// 用户得知道这一行会落到哪儿，"发到 storefront-a"和"发到 storefront-a 的哪个窗口"
    /// 在同一个项目开了三个会话时是两回事。
    public func locate(sessionId: String, session: AgentSession?) -> String? {
        guard let session else { return nil }
        let tree = ProcessTree.snapshot()
        if let pane = tmux.bindPanes(to: [session.pid], tree: tree)[session.pid] {
            return "tmux · \(pane.sessionName):\(pane.windowName)"
        }
        guard ITermLocator.isRunning() else { return nil }
        let terms = iterm.snapshot()
        let bound = JumpEngine.bind(
            itermSessions: terms, claudeSessions: [session], tree: tree
        )
        guard let uuid = bound[sessionId] else { return nil }
        let name = terms.first { $0.sessionUUID == uuid }?.name ?? ""
        return name.isEmpty ? "iTerm" : "iTerm · \(name)"
    }

    // MARK: - 留痕

    /// 护栏⑤。和审批日志放在一起 —— 两者是同一类东西：
    /// "Vibe Foreman 替我做了什么不可逆的事"。
    nonisolated static func log(text: String, sessionId: String, target: String) {
        HubLog.jump.notice(
            """
            岛上应答已发送 —— 会话 \(sessionId, privacy: .public) \
            目标 \(target, privacy: .public) 内容 \(text, privacy: .public)
            """
        )

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/claude-hub/reply-log.json"
            )
        var entries = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            ?? []
        entries.append([
            "at": ISO8601DateFormatter.string(
                from: Date(), timeZone: .current,
                formatOptions: [.withInternetDateTime]
            ),
            "sessionId": sessionId,
            "target": target,
            "text": text,
        ])
        // 只留最近 200 条，别让它无限涨。
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        if let data = try? JSONSerialization.data(
            withJSONObject: entries, options: [.prettyPrinted]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
