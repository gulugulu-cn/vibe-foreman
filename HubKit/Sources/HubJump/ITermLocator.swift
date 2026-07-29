import Foundation
import HubProbe

/// iTerm2 里的一个 session（= 一个 tab 里的一个分屏）。
public struct ITermSession: Hashable, Sendable {
    /// iTerm 自己的 session UUID。在 session 存活期间稳定，是我们的选择器。
    public let sessionUUID: String
    public let windowId: String
    /// iTerm 报告的该 session 前台作业 PID。
    ///
    /// **这是整个跳转方案的关键**：在 tmux `-CC` 控制模式下，`tty` 属性返回
    /// `missing value`，`tmuxPaneID` / `tmuxWindowName` 等变量也全是 `missing value`，
    /// 唯独 `jobPid` 有效且准确。
    public let jobPid: pid_t
    /// tab 标题。仅用于诊断输出，**不参与匹配** —— 它每轮都在变。
    public let name: String
}

/// 通过 AppleScript 枚举与操作 iTerm2。
///
/// AppleScript 的语法有个坑：读 session 变量必须写成
/// `tell s to get variable named "jobPid"`，写成 `variable named "jobPid" of s`
/// 会报 -1723「不允许访问」。
public struct ITermLocator: Sendable {
    public init() {}

    private static let fieldSep = "\u{1}"
    private static let rowSep = "\u{2}"

    /// 枚举 iTerm 当前全部 session。
    ///
    /// iTerm 没在运行、或未授予 Automation 权限时返回空数组。
    /// 这个调用有成本（AppleScript 跨进程），**只在跳转时按需调用，不要放进轮询循环**。
    public func snapshot() -> [ITermSession] {
        let script = """
        tell application "iTerm2"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set jp to "0"
                        try
                            tell s to set jp to (get variable named "jobPid") as text
                        end try
                        set out to out & (id of w) & "\(Self.fieldSep)" & (id of s) ¬
                            & "\(Self.fieldSep)" & jp & "\(Self.fieldSep)" & (name of s) ¬
                            & "\(Self.rowSep)"
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """

        let result = Shell.osascript(script, timeout: 6)
        guard result.succeeded else { return [] }

        return result.stdout.components(separatedBy: Self.rowSep).compactMap { row in
            let fields = row.components(separatedBy: Self.fieldSep)
            guard fields.count >= 4 else { return nil }
            // jobPid 为 0 表示 iTerm 报不出前台作业（session 刚建或已死），无法绑定。
            guard let pid = pid_t(fields[2].trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid > 0
            else { return nil }
            return ITermSession(
                sessionUUID: fields[1],
                windowId: fields[0],
                jobPid: pid,
                name: fields[3]
            )
        }
    }

    /// 前置到指定 session。成功返回 true。
    public func focus(sessionUUID: String) -> Bool {
        // 三个 select 缺一不可：select w 切窗口、select t 切 tab、select s 切分屏。
        // 只 activate 不 select 就是旧实现「跳到 iTerm 但停在原窗口」的毛病。
        let escaped = sessionUUID.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is "\(escaped)" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """
        let result = Shell.osascript(script, timeout: 6)
        return result.succeeded && result.stdout.contains("ok")
    }

    /// 当前处于前台的 session UUID。跳转后用它验证是否真的切过去了。
    public func frontmostSessionUUID() -> String? {
        let result = Shell.osascript(
            #"tell application "iTerm2" to return id of current session of current tab of current window"#,
            timeout: 4
        )
        guard result.succeeded else { return nil }
        let uuid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return uuid.isEmpty ? nil : uuid
    }

    /// iTerm 是否在运行。
    ///
    /// 没跑就别付 AppleScript 的成本 —— 更重要的是，对没运行的 app 发 AppleEvent
    /// 会**触发冷启动**，用户点一下跳转结果弹出个空 iTerm 窗口，体验很差。
    public static func isRunning() -> Bool {
        Shell.run("/usr/bin/pgrep", ["-x", "iTerm2"], timeout: 2).succeeded
    }
}
