import AppKit

/// 在鼠标位置弹一个原生 NSMenu。
///
/// 为什么不用 SwiftUI 的 Menu 做"整行点击弹菜单"：borderless menu 会把大
/// label 压成内容自适应宽度（行布局全毁）；透明盖层方案（Color.clear 当
/// label）在 macOS 上收不到点击。两条路都实测踩坑之后，回到 AppKit ——
/// NSMenu.popUpContextMenu 不依赖 SwiftUI 的 hit-testing，也不需要面板是
/// key window。
@MainActor
enum RowMenu {

    struct Item {
        let title: String
        let action: () -> Void

        init(_ title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }
    }

    /// items 里 nil 表示分隔线。
    static func present(_ items: [Item?]) {
        let menu = NSMenu()
        for item in items {
            if let item {
                menu.addItem(ClosureMenuItem(title: item.title, handler: item.action))
            } else {
                menu.addItem(.separator())
            }
        }
        guard let event = NSApp.currentEvent,
              let view = event.window?.contentView
        else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

/// 带闭包的菜单项。NSMenu 持有 item、item 以自身为 target —— 菜单收起后一起释放。
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func invoke() { handler() }
}
