import CryptoKit
import Foundation

/// 项目在密钥功能里的身份。**只此一处**，别的地方不许再算一遍。
///
/// ## 为什么要单独一个类型
///
/// 仓库里「项目的 key」有两个互不兼容的取法，而且两种都在用：
/// `ProjectStore.pinned` 用 `Project.id`（yaml 里的原文路径，含 `~`），
/// `AcceptanceStore.ledgers` 用 `expandedPath`（展开后的绝对路径）。
/// 各自都有道理，但这次的功能**两头都要碰**（绑定表按项目存，文件名按项目生成），
/// 混用一次就是一次静默事故：绑定表用一种、物化器用另一种，
/// 结果是项目怎么勾都拿不到密钥，而界面上一切正常。
///
/// 这里统一取 `expandedPath`，理由是文件名必须锚在**真实目录**上 ——
/// 见下面 `envFileName` 那段。
///
/// ## 文件名为什么要带哈希后缀
///
/// 这不是装饰。只用项目名的话，`~/code/a/api` 和 `~/code/b/api` 会写进同一个文件，
/// 于是**项目 A 拿到项目 B 的密钥** —— 这是安全事故，不是显示问题。
/// 而项目重名在真实机器上一点都不罕见（`api`、`server`、`web`、`admin`）。
///
/// 后缀取路径哈希的前 8 位（32 bit）。两个不同路径撞上的概率在几十个项目的量级下
/// 可以忽略，而路径仍然短到能一眼看懂、能复制粘贴 ——
/// 「能被复制粘贴」正是这些文件放在 `~/.vibe-foreman/` 而不是
/// `~/Library/Application Support/` 的唯一理由。
public enum ProjectKey {

    /// 绑定表、查表、一切按项目索引的地方都用它。
    public static func key(for project: Project) -> String {
        key(forPath: project.path)
    }

    /// 展开 `~`，去掉结尾的 `/`。
    ///
    /// 不用 `NSString.standardizingPath`：它在 macOS 上对 `/tmp` 有
    /// 「悄悄换成 `/private/tmp`」的特例，而且对不存在的路径行为不好预测 ——
    /// 项目目录被删掉之后仍然要能查到它的绑定，所以这里不碰文件系统。
    public static func key(forPath raw: String) -> String {
        let expanded = raw.hasPrefix("~") ? NSString(string: raw).expandingTildeInPath : raw
        var trimmed = expanded
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// 物化出来的 `.env` 文件名。
    public static func envFileName(for project: Project) -> String {
        envFileName(name: project.name, key: key(for: project))
    }

    public static func envFileName(name: String, key: String) -> String {
        "\(slug(name))-\(fingerprint(key)).env"
    }

    /// 只有这个形状的文件才是我们生成的，`reconcile` 也只敢删这个形状的。
    /// 用户自己往目录里放的东西一个都不能碰。
    public static func looksLikeGeneratedEnvFile(_ fileName: String) -> Bool {
        fileName.range(
            of: "^[a-z0-9_][a-z0-9_-]*-[0-9a-f]{8}\\.env$",
            options: .regularExpression
        ) != nil
    }

    // MARK: - 零件

    static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// 项目名 → 文件名安全的一段。中文项目名会被整段替换掉，
    /// 这没关系 —— 唯一性由后面的哈希保证，slug 只负责「人能认出来」。
    static func slug(_ name: String) -> String {
        var out = ""
        var lastWasDash = false
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if ch == "_" {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while out.hasPrefix("-") { out.removeFirst() }
        if out.count > 32 { out = String(out.prefix(32)) }
        while out.hasSuffix("-") { out.removeLast() }
        // 全是非 ASCII 的名字（比如「后台」）会被削成空串。
        // 回落成一个固定词，靠哈希区分，不要回落成路径 —— 那会把绝对路径写进文件名。
        return out.isEmpty ? "project" : out
    }
}
