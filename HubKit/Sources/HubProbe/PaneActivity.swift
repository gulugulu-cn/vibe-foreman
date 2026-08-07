import Foundation

/// 从终端画面判断一个会话是不是真的停下来了。
///
/// ## 为什么光看状态文件不够
///
/// `~/.claude/sessions/<pid>.json` 里的 `status` 是权威的，但它回答的问题
/// 和我们要问的不完全是一件事：
///
/// - `busy` = Claude 在思考 → 确实在干活；
/// - `shell` = **挂着一个后台 shell** —— 和 Claude 自己在不在干活无关。
///   实测它空在提示符上等输入时，状态照样是 `shell`。
///
/// 只信状态文件的话，`shell` 这一档会让盯梢彻底失效：实机上它停了 20 分钟
/// 一次都没被催到，是用户先发现的，不是程序。
///
/// 所以补一个屏幕信号。**这不是退回去靠截屏猜** —— 状态文件在 `shell` 这一点上
/// 信息不足，两个信号合起来才准，各自单独都不够。
///
/// ## 为什么这些函数是纯的
///
/// 它们是整套盯梢里唯一容易写错、而且**写错了不会报错只会静默失灵**的部分。
/// 做成纯字符串函数之后，每一种画面形态都能钉一条测试，不用去起真的终端。
public enum PaneActivity {

    /// 画面上有没有"转圈计时"。
    ///
    /// Claude Code 在干活时底部会有一行像
    /// `✻ Boondoggling… (17s · ↓ 201 tokens)` —— 关键特征是那个
    /// `(数字s · ` 或 `(数字m 数字s · `。动词和字符会变（Wandering /
    /// Boondoggling / ✻ / ✽ / ✳），**别去匹配它们**，那是一份永远补不完的名单。
    public static func isWorking(pane: String) -> Bool {
        for line in pane.split(separator: "\n") {
            if durationPattern.firstMatch(
                in: String(line), range: NSRange(line.startIndex..., in: line)
            ) != nil {
                return true
            }
        }
        return false
    }

    /// `(17s · ` / `(21m 51s · ` —— 计时加中点，是转圈行的稳定特征。
    private static let durationPattern = try! NSRegularExpression(
        pattern: #"\([0-9]+(m [0-9]+)?s · "#
    )

    /// 输入框里有没有用户还没发完的字。
    ///
    /// **有就绝对不能发追问。** `tmux send-keys` 是往当前输入位置敲字，
    /// 用户正在打字时会直接拼到他那句后面 —— 实机上真发生过，把用户的话
    /// 和追问接成了一句。轻则语义变了，重则改变他本来要说的意思。
    ///
    /// 取的是**最后一行** `❯` 开头的：画面上方的历史消息里也有 `❯`，
    /// 只有最后那个是当前输入框。
    public static func draft(pane: String) -> String? {
        let prompts = pane.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("❯") }
        guard let last = prompts.last else { return nil }

        let text = last.dropFirst()   // 去掉 ❯
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Claude Code 在有排队消息时会把这行显示成提示语，那不是用户的草稿。
        guard !placeholders.contains(where: text.hasPrefix) else { return nil }
        return text
    }

    /// 输入框位置上会出现的、**不是用户输入**的提示语。
    ///
    /// 把它们当成草稿的话，一旦有消息排队盯梢就再也不敢发言了 ——
    /// 而排队恰恰说明它正忙，忙完就会读，这时候补一条完全没问题。
    private static let placeholders = [
        "Press up to edit queued messages",
        "Try ", "Ask ",
    ]

    /// 综合判断：这个会话现在能不能被打扰。
    ///
    /// - Parameter status: 状态文件里的 `status`。
    /// - Returns: nil = 可以打扰；非 nil = 不能，值是原因（写进日志用）。
    public static func doNotDisturb(status: String?, pane: String) -> String? {
        if status == "busy" { return "在思考" }
        if isWorking(pane: pane) { return "屏幕在转圈" }
        if let draft = draft(pane: pane) {
            return "输入框里有没发完的字：\(draft.prefix(20))"
        }
        return nil
    }
}
