import Foundation

/// 审批链路上的超时阶梯。
///
/// ## 顺序必须严格递增，否则安全默认值会反过来
///
/// 实测踩到的坑：一开始 `ApprovalCoordinator` 和 hubctl 的读超时都设成 60 秒，
/// 结果两者同时到期，hubctl 先判定"没收到应答"并按 fail-open **放行**了一条
/// `git push --force origin main` —— 而服务端那一侧其实已经决定拒绝。
/// 超时的语义从"安全拒绝"变成了"静默放行"，正好是设计意图的反面。
///
/// 正确的阶梯：**内层先到期，外层留足余量收结果**。
///
/// ```
///  60s  ApprovalCoordinator  用户没反应 → 判定拒绝
///  65s  HookCoordinator      等 UI 那边把拒绝送回来
///  75s  hubctl 读 socket     等服务端把拒绝写回来
///  90s  settings.json        Claude 杀掉 hook 进程的上限
/// ```
///
/// 每一层都必须**大于**它内层的那一层。任何一层反过来，就会出现
/// 「内层判定拒绝、外层已经超时放行」的危险窗口。
public enum HookTimeouts {

    /// 用户在岛上决策的时限。到点自动拒绝。
    public static let userDecision: TimeInterval = 60

    /// 服务端等 UI 把结论送回来。
    public static let serverBridge: TimeInterval = 65

    /// hubctl 等服务端应答。
    public static let clientRead: TimeInterval = 75

    /// 写进 settings.json 的 hook 超时。Claude 超过这个时间会杀掉 hubctl。
    ///
    /// 必须大于 `clientRead`，否则 hubctl 还没来得及输出拒绝就被杀了，
    /// 而被杀的 hook 等同于没有输出 —— 也就是放行。
    public static let hookProcess: Int = 90
}
