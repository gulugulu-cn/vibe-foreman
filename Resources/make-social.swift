import AppKit
import CoreGraphics
import Foundation
import ImageIO

// GitHub 的社交预览图（1280×640）。
//
// 这张图是仓库被分享到 Twitter / Slack / 飞书时唯一会被看到的东西 ——
// 没有它，链接展开后是一片灰底加一行小字，看起来像个废弃项目。
//
// 沿用 app 图标的视觉语言：近黑底 + 青→蓝→紫→品红→橙的渐变胶囊。
// 图标本身直接读 AppIcon.icns 里那张 1024，不重画一遍 ——
// 两处各画一遍必然漂移，而"两个地方的图标不一样"是最廉价也最刺眼的破绽。

let W: CGFloat = 1280
let H: CGFloat = 640

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconURL = here.appendingPathComponent("AppIcon.icns")
let outURL = here.deletingLastPathComponent()
    .appendingPathComponent("docs/social-preview.png")

guard let iconImage = NSImage(contentsOf: iconURL) else {
    FileHandle.standardError.write(Data("找不到 AppIcon.icns\n".utf8))
    exit(1)
}

guard let ctx = CGContext(
    data: nil, width: Int(W), height: Int(H),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

ctx.setAllowsAntialiasing(true)

// ── 底：近黑，带一点从左下往右上的提亮，别做成死板的纯色块。
let space = CGColorSpaceCreateDeviceRGB()
if let bg = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(red: 0.055, green: 0.055, blue: 0.075, alpha: 1),
        CGColor(red: 0.098, green: 0.094, blue: 0.129, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: []
    )
}

// ── 图标背后的光晕。图标是深色的，直接压在深色底上会糊成一团。
ctx.saveGState()
let glowCenter = CGPoint(x: 300, y: H / 2)
if let glow = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(red: 0.45, green: 0.35, blue: 0.95, alpha: 0.32),
        CGColor(red: 0.45, green: 0.35, blue: 0.95, alpha: 0),
    ] as CFArray,
    locations: [0, 1]
) {
    ctx.drawRadialGradient(
        glow, startCenter: glowCenter, startRadius: 0,
        endCenter: glowCenter, endRadius: 300, options: []
    )
}
ctx.restoreGState()

// ── 图标
let iconSide: CGFloat = 300
let iconRect = CGRect(
    x: glowCenter.x - iconSide / 2, y: H / 2 - iconSide / 2,
    width: iconSide, height: iconSide
)
var proposed = iconRect
if let cg = iconImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
    ctx.draw(cg, in: iconRect)
}

// ── 文字。用 AppKit 画，CoreText 手搓一遍不值得。
let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gfx

func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight,
          color: NSColor, tracking: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 1.1
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
        .paragraphStyle: style,
    ]
    NSAttributedString(string: text, attributes: attrs).draw(at: point)
}

let textX: CGFloat = 520

draw("Vibe Foreman", at: CGPoint(x: textX, y: 372), size: 76, weight: .bold,
     color: .white, tracking: -1.5)

draw("给 vibe coding 当工头", at: CGPoint(x: textX, y: 312), size: 30, weight: .medium,
     color: NSColor(calibratedRed: 0.72, green: 0.70, blue: 0.85, alpha: 1))

// 这两行是全图唯一在说"它和别的监控工具有什么不同"的地方。
draw("不只看见 AI agent 在干嘛，", at: CGPoint(x: textX, y: 244), size: 26,
     weight: .regular, color: NSColor(white: 0.62, alpha: 1))
draw("还盯着它有没有真的把活干完。", at: CGPoint(x: textX, y: 206), size: 26,
     weight: .regular, color: NSColor(white: 0.62, alpha: 1))

NSGraphicsContext.restoreGraphicsState()

// ── 底部那道渐变细线：把图标上的配色再点一次，收住整张图。
if let line = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(red: 0.30, green: 0.78, blue: 0.95, alpha: 1),
        CGColor(red: 0.45, green: 0.45, blue: 0.95, alpha: 1),
        CGColor(red: 0.85, green: 0.35, blue: 0.75, alpha: 1),
        CGColor(red: 0.98, green: 0.55, blue: 0.35, alpha: 1),
    ] as CFArray,
    locations: [0, 0.35, 0.7, 1]
) {
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: 8))
    ctx.drawLinearGradient(
        line, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: 0), options: []
    )
    ctx.restoreGState()
}

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        outURL as CFURL, "public.png" as CFString, 1, nil
      )
else { exit(1) }

CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("已生成 \(outURL.path)")
