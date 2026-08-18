import AppKit
import Foundation

/// 复制到剪贴板。
///
/// 原来这三行在 `SessionDetailCard` 和 `MainWindow` 里各内联了一遍，都是 private。
/// 提到这里不只是去重 —— 密码那条路要多做两件事，散在两处必然只改一处。
@MainActor
public enum Clipboard {

    /// 普通内容：命令、路径、提示语。
    public static func copy(_ value: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
    }

    /// 密码、密钥这类不该留痕的内容。
    ///
    /// 两件普通复制不做的事：
    ///
    /// 1. 打上 `org.nspasteboard.ConcealedType`。剪贴板管理器
    ///    （Maccy / Paste / Raycast 之类）约定看到这个类型就不记历史 ——
    ///    否则密码会安安静静躺在一个没有任何保护的历史列表里。
    /// 2. 到点自动清空。
    ///
    /// **清空前必须比对 `changeCount`。** 用户在这几十秒里多半会复制别的东西，
    /// 那时剪贴板里已经是他要的内容了，到点还去 `clearContents()` 就变成
    /// 「复制了个链接，一分钟后剪贴板莫名其妙空了」—— 这种 bug 用户根本不会
    /// 联想到密码功能上，只会觉得系统抽风。
    public static func copySecret(_ value: String, clearAfter seconds: TimeInterval = 45) {
        let board = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        board.declareTypes([.string, concealed], owner: nil)
        board.setString(value, forType: .string)
        board.setString("", forType: concealed)

        // declareTypes 已经把 changeCount 推进过了，setString 不会再动它，
        // 所以这里取到的就是「我们这次复制」的版本号。
        let stamp = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard NSPasteboard.general.changeCount == stamp else { return }
            NSPasteboard.general.clearContents()
        }
    }
}
