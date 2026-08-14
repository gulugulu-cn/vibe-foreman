import HubProjects

/// 项目行的菜单内容。
///
/// **岛和主窗口共用这一份。** 两边各写一遍的话必然漂移 —— 实际上已经漂过：
/// 岛的菜单里有「接着上次」，主窗口的没有，同一个项目在两个界面上能做的事
/// 不一样，而用户没有任何线索知道为什么。
///
/// 三个入口都走这里：右键、"…" 按钮、主窗口的 ▶ 按钮。
@MainActor
enum ProjectMenu {

    /// - Parameter resumable: 上一个被「关窗即结束」收掉、且接得回来的会话。
    ///   有它就排第一 —— 关掉窗口后回来的人想接着往下走，
    ///   不是从空白开一个新的。
    static func items(
        isPinned: Bool,
        resumable: ClosedSession?,
        /// 目录已经不在了。这时候不该给"开项目"的选项 —— tmux 对不存在的
        /// `-c` 目录返回 0 并静默回落到家目录，点了只会开出一个开在家目录的
        /// claude，然后用户以为是菜单坏了。只留「从列表移除」。
        isMissing: Bool = false,
        onLaunch: @escaping (LaunchMode) -> Void,
        onTogglePin: @escaping () -> Void,
        onRemove: (() -> Void)? = nil
    ) -> [RowMenu.Item?] {
        var items: [RowMenu.Item?] = []

        // 目录没了就只给「移除」这一条。
        //
        // **一个都不留是刻意的**：这里能放的每一项（开 Claude、开终端、
        // 开 Finder）在目录不存在时全都是"点了没反应"或者"开到家目录"，
        // 而这次事故的全部内容就是这些静默失败。
        // 给一个假的可点项，等于把刚修好的问题又造一遍。
        if isMissing {
            items.append(RowMenu.Item("⚠︎ 目录已不存在，无法打开", action: {}))
            items.append(nil)
            if let onRemove {
                items.append(RowMenu.Item("从列表移除", action: onRemove))
            }
            return items
        }

        if let resumable {
            items.append(RowMenu.Item(
                "接着上次（\(RelativeTime.short(from: resumable.endedAt))前结束）"
            ) { onLaunch(.resumeSession) })
            items.append(nil)
        }

        // `.resumeSession` 不进这一段：它要一个具体的 sessionId，
        // 而那个 id 只有上面那条「接着上次」知道。菜单里再放一个同名项
        // 只会退化成 `claude --resume` 的交互列表。
        items += LaunchMode.allCases
            .filter { $0 != .resumeSession }
            .map { mode in RowMenu.Item(mode.label) { onLaunch(mode) } }

        items.append(nil)
        items.append(RowMenu.Item(isPinned ? "取消置顶" : "置顶", action: onTogglePin))
        if let onRemove {
            items.append(RowMenu.Item("从列表移除", action: onRemove))
        }
        return items
    }
}
