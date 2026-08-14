import AppKit
import SwiftUI

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

/// 右键（以及 ctrl+左键）捕获层。
///
/// ## 为什么不用 `.contextMenu`
///
/// SwiftUI 的 `.contextMenu` 在岛上不可靠 —— 岛是个基本不做 key window 的
/// NSPanel，而 SwiftUI 的菜单要走它自己那套 hit-testing。同一个坑在
/// `RowMenu` 的注释里已经记了一次（borderless Menu 压扁布局、透明盖层
/// 收不到点击）。这里直接用 AppKit 收事件，和 `RowMenu.present` 是同一条路。
///
/// ## 为什么要重写 `hitTest`
///
/// 盖在整行上的 NSView 默认会把**左键**也吃掉，那样整行点击（跳转会话 /
/// 起一个新的）就全废了 —— 加了个右键菜单反而把主功能弄没了。
/// 所以只在当前事件是右键、或 ctrl+左键（macOS 的等价操作）时才认领点击，
/// 其余一律返回 nil 让它穿透下去。
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown, .leftMouseUp:
                // **不能写成 `case .leftMouseDown, .leftMouseUp where …`** ——
                // Swift 里 `where` 只作用于最后一个 pattern，`.leftMouseDown`
                // 会无条件命中，于是这一层把所有左键都吃掉，整行点击全废。
                // 编译器会警告，别把这条警告当噪音。
                return event.modifierFlags.contains(.control)
                    ? super.hitTest(point) : nil
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }

        /// ctrl+左键。macOS 上单键鼠标/触控板的人用的就是这个，
        /// 只认 rightMouseDown 会让他们以为功能没做。
        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else {
                super.mouseDown(with: event)
                return
            }
            onRightClick?()
        }
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
