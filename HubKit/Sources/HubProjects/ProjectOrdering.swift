import Foundation

/// 项目列表的排序规则。抽成纯函数：岛和主窗口共用一套口径，
/// 写在 View 里既没法测，也迟早会悄悄分叉。
public enum ProjectOrdering {

    /// 统一口径：**置顶 > 正在开发（有会话在跑）> 最近有提交 > 名字**。
    ///
    /// 为什么是这个顺序：
    /// - 置顶是用户明确表达过的"我要它在最上面"，压过一切瞬时状态；
    /// - "现在有会话在跑"就是此刻正在做的事，找它的概率最高；
    /// - 其余按最后提交时间倒序 —— 三四十个项目按 yaml 顺序排的话，
    ///   找一个要翻半屏，而人真正会回去的基本都是最近动过的那几个；
    /// - 从来没提交过 / 读不到 git 的排最后，同档按名字，保证顺序稳定
    ///   （列表每 6 秒刷新一次，排序不稳定会让行来回跳）。
    public static func rank(
        _ projects: [Project],
        pinned: Set<String>,
        runningCount: (Project) -> Int,
        lastCommitAt: (Project) -> Date?
    ) -> [Project] {
        projects.sorted { lhs, rhs in
            let lPinned = pinned.contains(lhs.id)
            let rPinned = pinned.contains(rhs.id)
            if lPinned != rPinned { return lPinned }

            let lRunning = runningCount(lhs) > 0
            let rRunning = runningCount(rhs) > 0
            if lRunning != rRunning { return lRunning }

            switch (lastCommitAt(lhs), lastCommitAt(rhs)) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 岛上的口径。和主窗口同一套，只是岛上没有搜索框，直接排全量。
    public static func islandOrder(
        _ projects: [Project],
        pinned: Set<String>,
        runningCount: (Project) -> Int,
        lastCommitAt: (Project) -> Date? = { _ in nil }
    ) -> [Project] {
        rank(projects, pinned: pinned, runningCount: runningCount, lastCommitAt: lastCommitAt)
    }

    /// 只把置顶项提前，两组内部都保持传入顺序。
    /// 需要"完全不打乱原始顺序"的场景用它（当前没有调用方，保留给按 yaml
    /// 手工分组浏览的场景）。
    public static func pinnedFirst(_ projects: [Project], pinned: Set<String>) -> [Project] {
        guard !pinned.isEmpty else { return projects }
        return projects.filter { pinned.contains($0.id) }
            + projects.filter { !pinned.contains($0.id) }
    }
}
