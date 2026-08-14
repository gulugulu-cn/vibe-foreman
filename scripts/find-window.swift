import CoreGraphics
import Foundation

// 找出灵动岛那个窗口的 id，给 `screencapture -l` 用。
//
// 为什么不用 AppleScript：岛是个 `.nonactivatingPanel` 的无边框 NSPanel，
// System Events 那套 accessibility 接口对它基本是瞎的（拿不到 window 1），
// 而且走那条路要 Accessibility 授权。CGWindowList 只需要屏幕录制权限，
// 而截图本来就要那个权限，不多欠一份。
//
// 输出：`<窗口id> <宽> <高>`，按面积从大到小。最大的那个就是岛
//（app 还会有几个 1×1 的辅助窗口）。

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]] else { exit(1) }

struct Found {
    let id: Int
    let width: Int
    let height: Int
    var area: Int { width * height }
}

let found: [Found] = windows.compactMap { window in
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          // CGWindowList 报的是**显示名**（CFBundleName），不是可执行名。
          // 写死 "ClaudeHub" 会一个窗口都找不到 —— 第一版就是这么空手而归的。
          owner.contains("Foreman") || owner == "ClaudeHub",
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double,
          // 1×1 的辅助窗口和 0 尺寸的占位窗口全部排掉。
          width > 40, height > 40
    else { return nil }
    return Found(id: id, width: Int(width), height: Int(height))
}

for window in found.sorted(by: { $0.area > $1.area }) {
    print("\(window.id) \(window.width) \(window.height)")
}
