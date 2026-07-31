import AppKit
import CoreGraphics
import ImageIO
import Foundation

// Claude Hub 的 app 图标。
//
// 属于 agentx 系列，所以沿用那一套视觉语言：青→蓝→紫→品红→橙的渐变，
// 加一颗四角星芒。但主体换成**灵动岛本身的胶囊形** —— 这是这个 app
// 唯一的门面，也是它在无刘海屏上的真实形态。
//
// 极简的判据是"16pt 下还认得出"：一个胶囊 + 一颗星，没有任何细节需要分辨。

func makeIcon(size: CGFloat) -> CGImage? {
    let scale: CGFloat = size / 1024
    guard let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)

    // macOS 图标网格：1024 画布里图形只占 824，四周各留 100。
    // 不留的话在 Dock 里会比别的 app 明显大一圈。
    let inset: CGFloat = 100
    let box = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let squircle = CGPath(
        roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil
    )

    // ── 底：接近纯黑，和刘海同一个色系。
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1),
            CGColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        bg, start: CGPoint(x: box.minX, y: box.maxY),
        end: CGPoint(x: box.maxX, y: box.minY), options: []
    )

    // ── 主体：灵动岛的胶囊。
    //
    // 尺寸按"一眼能认出是个横向药丸"来定：占内框 62% 宽、22% 高。
    // 再细就会在 16pt 下糊成一条线，再粗就不像岛了。
    let pillW = box.width * 0.62
    let pillH = box.height * 0.22
    let pill = CGRect(
        x: box.midX - pillW / 2,
        y: box.midY - pillH / 2 + box.height * 0.02,
        width: pillW, height: pillH
    )
    let pillPath = CGPath(
        roundedRect: pill, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil
    )

    // 外发光。agentx 那两个图标都有明显的辉光，少了就不像一家的。
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero, blur: 90,
        color: CGColor(red: 0.55, green: 0.35, blue: 0.95, alpha: 0.85)
    )
    ctx.addPath(pillPath)
    ctx.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.9, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 渐变填充，斜向 —— 和 agentx 的 A 字走向一致。
    ctx.saveGState()
    ctx.addPath(pillPath)
    ctx.clip()
    let brand = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1),   // 青
            CGColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1),   // 蓝
            CGColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1),   // 紫
            CGColor(red: 0.93, green: 0.28, blue: 0.60, alpha: 1),   // 品红
            CGColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1),   // 橙
        ] as CFArray,
        locations: [0, 0.28, 0.55, 0.80, 1]
    )!
    ctx.drawLinearGradient(
        brand, start: CGPoint(x: pill.minX, y: pill.maxY),
        end: CGPoint(x: pill.maxX, y: pill.minY), options: []
    )
    // 顶部高光：真实玻璃边缘因折射而更亮，岛本身也是这么画的。
    let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.42),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        sheen, start: CGPoint(x: pill.midX, y: pill.maxY),
        end: CGPoint(x: pill.midX, y: pill.midY), options: []
    )
    ctx.restoreGState()

    // ── 星芒。agentx 系列的共同记号，位置照搬：主体右上方。
    func sparkle(center: CGPoint, radius: CGFloat, waist: CGFloat, alpha: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: center.x, y: center.y + radius))
        p.addQuadCurve(
            to: CGPoint(x: center.x + radius, y: center.y),
            control: CGPoint(x: center.x + waist, y: center.y + waist)
        )
        p.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y - radius),
            control: CGPoint(x: center.x + waist, y: center.y - waist)
        )
        p.addQuadCurve(
            to: CGPoint(x: center.x - radius, y: center.y),
            control: CGPoint(x: center.x - waist, y: center.y - waist)
        )
        p.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y + radius),
            control: CGPoint(x: center.x - waist, y: center.y + waist)
        )
        p.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero, blur: 26,
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.7)
        )
        ctx.addPath(p)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 16pt 下星芒只占两三个像素，糊成一个小污点，反而像脏了。
    // 光学尺寸的常规做法：小尺寸减细节，让主体独自承担识别。
    if size >= 32 {
        sparkle(
            center: CGPoint(x: pill.maxX - pillH * 0.12, y: pill.maxY + pillH * 0.42),
            radius: pillH * 0.46, waist: pillH * 0.07, alpha: 0.97
        )
    }

    ctx.restoreGState()
    return ctx.makeImage()
}

// ── 输出 iconset
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (px, name) in sizes {
    guard let image = makeIcon(size: CGFloat(px)) else { continue }
    let url = out.appendingPathComponent("\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { continue }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
print("已生成 \(sizes.count) 个尺寸 → \(out.path)")
