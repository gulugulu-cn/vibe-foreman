import Foundation
import os

/// 统一日志。
///
/// ## 为什么不用 `NSLog`
///
/// 被坑过两次：`NSLog("会话数 \(count)")` 在 `log show` 里显示成 `<private>` ——
/// 统一日志默认把所有插值当敏感数据。排障时看到一串 `<private>`，等于没打日志。
///
/// 而 `NSLog("%{public}d", count)` 也是错的：`{public}` 是 `os_log` 的格式语法，
/// `NSLog` 不认，会把 `{public}d` 原样打出来。**只有 `Logger` 的 `privacy:` 参数
/// 是对的做法。**
///
/// 这里的内容都是本机路径、会话数、决策结果，没有敏感信息，所以一律 public。
public enum HubLog {

    private static let subsystem = "dev.hengjun.claude-hub"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let island = Logger(subsystem: subsystem, category: "island")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    public static let jump = Logger(subsystem: subsystem, category: "jump")

    /// 看日志的命令，写在这里省得每次去翻。
    ///
    ///     log stream --predicate 'subsystem == "dev.hengjun.claude-hub"' --style compact
    ///     log show   --predicate 'subsystem == "dev.hengjun.claude-hub"' --last 10m --style compact
    public static let howToRead = """
    log stream --predicate 'subsystem == "dev.hengjun.claude-hub"' --style compact
    """
}
