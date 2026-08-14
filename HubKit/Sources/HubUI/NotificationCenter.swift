import AppKit
import Foundation
import UserNotifications

/// 系统通知。
///
/// ## 为什么换掉 terminal-notifier
///
/// 旧实现在 bash hook 里调 `terminal-notifier -activate com.googlecode.iterm2`。
/// 两个致命问题：
/// 1. `-activate` **只能把 iTerm 整个 app 拉到前台，无法选中具体 tab** ——
///    这正是用户抱怨"点了通知跳到 iTerm 但停在原来那个窗口"的直接原因；
/// 2. 外部进程发的通知，我们的 app 拿不到点击回调，想补救也补救不了。
///
/// 换成 app 内的 `UNUserNotificationCenter` 之后，点击会回到本进程，
/// 我们就能拿着 sessionId 去跑精准跳转。
///
/// ## 为什么 userInfo 里放 sessionId 而不是项目名
///
/// 项目名会重（多个 worktree 同名）、tmux 窗口名会被 automatic-rename 改掉。
/// sessionId 是 UUID，全局唯一且在会话生命周期内不变。
@MainActor
public final class HubNotificationCenter: NSObject, UNUserNotificationCenterDelegate {

    /// nonisolated：delegate 回调在非主线程读它。常量字符串本来就是并发安全的。
    public nonisolated static let sessionIdKey = "hub.sessionId"

    /// 点击通知时调用。参数是 sessionId。
    public var onActivate: ((String) -> Void)?

    private var authorized = false

    public override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, error in
            Task { @MainActor in
                self?.authorized = granted
                if let error {
                    NSLog("[ClaudeHub] 通知授权失败：\(error.localizedDescription)")
                } else if !granted {
                    NSLog("[ClaudeHub] 用户拒绝了通知权限，只有灵动岛会提示")
                }
            }
        }
    }

    /// - Parameter distinctBy: 给 identifier 加的后缀。
    ///
    ///   默认（nil）时同一会话共用一个 id，新通知**静默替换**旧的 ——
    ///   这对"跑得快的会话刷屏"是对的。
    ///
    ///   但静默替换意味着**不会重新弹横幅**，而滞留提醒升级到第三轮时
    ///   恰恰需要重新弹一次（用户前两次就是没看到才升级的）。
    ///   那种场合传一个不同的后缀，让系统当成一条新通知。
    public func post(
        title: String,
        body: String,
        sessionId: String,
        sound: Bool = true,
        distinctBy: String? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.sessionIdKey: sessionId]
        if sound { content.sound = .default }

        let suffix = distinctBy.map { ".\($0)" } ?? ""
        let request = UNNotificationRequest(
            identifier: "hub.session.\(sessionId)\(suffix)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[ClaudeHub] 发送通知失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // 这两个必须是 nonisolated：协议要求本身不是 MainActor 隔离的，
    // 而它们的参数（UNNotification 等）不是 Sendable，Swift 6 不允许跨隔离域传递。
    // 所以在这里就地取出需要的值（String 是 Sendable），再跳回主线程。

    /// app 在前台时也要显示横幅。
    ///
    /// Vibe Foreman 是 `.accessory` 类型，本来就不"在前台"，但用户点开主窗口时
    /// 它会变成活跃 app，这时通知照样得显示 —— 用户要的是知道别的会话怎么样了。
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 点击通知 → 精准跳回对应会话的终端 tab。
    ///
    /// 这就是本次重写要修的那个 bug：旧实现用 terminal-notifier，
    /// 外部进程发的通知拿不到点击回调，`-activate` 又只能前置 app 不能选 tab。
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.content
            .userInfo[Self.sessionIdKey] as? String

        // completionHandler 不是 Sendable，不能带进 Task。系统只要求它被调用，
        // 不要求等跳转做完 —— 跳转本来就是异步的（要跑 AppleScript）。
        completionHandler()

        guard let sessionId else { return }
        Task { @MainActor in
            self.onActivate?(sessionId)
        }
    }
}
