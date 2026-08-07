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

    /// 交互卡（选择题 / 计划审批）上用户作答的时限。
    ///
    /// 到点**放行**而不是拒绝 —— 语义和 `userDecision` 相反：审批的超时
    /// 默认值是安全刹车（deny），交互卡的超时是"把问题交还给终端的原生
    /// 对话框"（不输出决策 = Claude 走正常权限流程，终端照常弹框）。
    /// 阶梯约束相同：必须 < `serverBridge`，内层先到期。
    public static let promptDecision: TimeInterval = 55

    /// 服务端等 UI 把结论送回来。
    public static let serverBridge: TimeInterval = 65

    /// hubctl 等服务端应答。
    public static let clientRead: TimeInterval = 75

    /// 写进 settings.json 的 hook 超时。Claude 超过这个时间会杀掉 hubctl。
    ///
    /// 必须大于 `clientRead`，否则 hubctl 还没来得及输出拒绝就被杀了，
    /// 而被杀的 hook 等同于没有输出 —— 也就是放行。
    public static let hookProcess: Int = 90

    // MARK: - Stop 的阶梯（独立的一组，和上面那条不共用）
    //
    // Stop 变成阻塞式之后，**每一次收工都要等 Hub 应答**。挂在上面那条
    // 75 秒的阶梯上是不能接受的：Hub 卡住时用户每说一句话就要干等 75 秒。
    //
    // 更重要的是**方向相反**。审批链路上超时 = 拒绝（安全刹车）；
    // Stop 链路上超时 = **不拦**。写反的话，Hub 一出问题所有会话就再也
    // 收不了工 —— 那是比"少提醒一次验收"严重得多的故障。
    //
    // ```
    //   3s  HookCoordinator   等 MainActor 算出该不该拦 → 到点就不拦
    //   5s  hubctl 读 socket  等服务端应答 → 到点什么都不输出 = 正常收工
    //  10s  settings.json     Claude 杀掉 hubctl 的上限
    // ```
    //
    // 三个数都小得多，因为这里不需要等人 —— 该不该拦是查内存里的清单，
    // 毫秒级就有答案。留 3 秒纯粹是给 MainActor 排队的余量。

    /// 服务端等 MainActor 给出"拦不拦"。到点 = 不拦。
    public static let stopBridge: TimeInterval = 3

    /// hubctl 等服务端应答。到点 = 什么都不输出 = 正常收工。
    public static let stopRead: TimeInterval = 5

    /// 写进 settings.json 的 Stop hook 超时。
    public static let stopHookProcess: Int = 10
}
