import AppKit
import CoreGraphics
import Foundation
import ImageIO

// 把全部截图拼成一张「一眼看完」的功能长图。
//
// 用途：发到社群 / 公众号 / 知乎时，一张图讲完这个工具是什么。
// 单张截图各自都很清楚，但分散着发没人会逐张点开。
//
// **只用 docs/screenshots/ 里那八张。** 那批全是 DemoFixtures 合成数据
//（storefront / api-gateway / billing-service 都是假的），逐张核对过。
// 拿真实工作区截的图绝不能进这里 —— 验收页尤其危险，它逐条显示着
// 你的需求原文和项目名。

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()
let shots = root.appendingPathComponent("docs/screenshots")
let outURL = root.appendingPathComponent("docs/poster.png")

let W: CGFloat = 1680
let margin: CGFloat = 80
let contentW = W - margin * 2

/// 一行：一到两张图 + 各自的说明。
struct Row {
    let items: [(file: String, title: String, note: String)]
}

let rows: [Row] = [
    Row(items: [("01-hover.png",
                 "① 鼠标划过刘海",
                 "每个会话一个小人：敲键盘 = 在干活，举手 = 在等你。\n需要你处理的那个被琥珀色框住。")]),
    Row(items: [("02-expanded-sessions.png",
                 "② 点开看全部",
                 "目录、分支、未提交数、运行了多久、\n在哪个终端里。等你处理的排第一。"),
                ("03-expanded-projects.png",
                 "③ 从岛上直接开项目",
                 "跑着会话的排前面，点一下切过去；\n没跑的点一下直接起一个。")]),
    Row(items: [("05-nudge.png",
                 "④ 卡住了会一直提醒",
                 "分得清卡在什么上：断线了 / 在问你 /\n等授权 / 还有待办 / 干完了等验收。"),
                ("06-answer.png",
                 "⑤ 不用切过去，在岛上答",
                 "选项由 AI 从上下文里给。\n点了不会直接发，先让你确认一次。")]),
    // 验收页放最后、给满幅 —— 这是整个工具的差异化所在，
    // 别的同类产品都在做"看见 agent 在干嘛"，只有这一页在回答"它有没有真的做到"。
    //
    // 它同时也顶掉了原来那张主窗口截图：验收页本来就带着主窗口的侧边栏，
    // 一张顶两张，而且旧那张的标题栏还写着改名前的名字。
    Row(items: [("09-acceptance.png",
                 "⑥ 它说做完了？拿真实 diff 复核",
                 "要点来自你的原话和你批准过的计划，不是 Claude 自己列的 todo。它自报做完之后，Hub 拿真实的 git diff 去对 —— 找不到对应改动的会被单独列进「疑似未做」。")]),
]

// ── 度量：先算出总高度，再一次性画。
let headerH: CGFloat = 340
let titleH: CGFloat = 46
let noteH: CGFloat = 76
let gap: CGFloat = 30
let rowGap: CGFloat = 78
let footerH: CGFloat = 150

func load(_ name: String) -> NSImage? {
    NSImage(contentsOf: shots.appendingPathComponent(name))
}

/// 真实像素尺寸。
///
/// **不能用 `NSImage.size`** —— 它返回的是「点」。这批截图是 Retina 抓的
/// （2x），1880px 的主窗口图它报 940，于是 `min(slot, size.width)` 把大图
/// 按小图处理，排出来只占半幅。第一版就是这么糊的。
func pixelSize(_ image: NSImage) -> CGSize {
    for rep in image.representations {
        if rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
    }
    return image.size
}

/// 一行里每张图能占多宽（两张时对半分，减掉中缝）。
func slotWidth(_ count: Int) -> CGFloat {
    count == 1 ? contentW : (contentW - gap) / 2
}

func rowHeight(_ row: Row) -> CGFloat {
    let slot = slotWidth(row.items.count)
    let tallest = row.items.compactMap { item -> CGFloat? in
        guard let image = load(item.file) else { return nil }
        let size = pixelSize(image)
        // 不放大：这批图是 2x 抓的，按原像素摆最清楚，拉伸只会糊。
        let width = min(slot, size.width)
        return size.height * (width / size.width)
    }.max() ?? 0
    return titleH + noteH + tallest
}

let totalH = headerH + rows.reduce(0) { $0 + rowHeight($1) + rowGap } + footerH

guard let ctx = CGContext(
    data: nil, width: Int(W), height: Int(totalH),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
ctx.setAllowsAntialiasing(true)

let space = CGColorSpaceCreateDeviceRGB()

// ── 底
if let bg = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(red: 0.043, green: 0.043, blue: 0.059, alpha: 1),
        CGColor(red: 0.086, green: 0.082, blue: 0.114, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        bg, start: CGPoint(x: 0, y: totalH), end: CGPoint(x: W, y: 0), options: []
    )
}

let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gfx

func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight,
          color: NSColor, tracking: CGFloat = 0, lineHeight: CGFloat = 1.35) {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = lineHeight
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
        .paragraphStyle: style,
    ]).draw(at: point)
}

// ── 头部
var y = totalH - 120

if let icon = NSImage(contentsOf: root.appendingPathComponent("docs/icon.png")) {
    var rect = CGRect(x: margin, y: y - 20, width: 96, height: 96)
    if let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
        ctx.draw(cg, in: rect)
    }
}

draw("Vibe Foreman", at: CGPoint(x: margin + 124, y: y + 38), size: 60, weight: .bold,
     color: .white, tracking: -1.2)
draw("给 vibe coding 当工头", at: CGPoint(x: margin + 126, y: y - 6), size: 26,
     weight: .medium, color: NSColor(calibratedRed: 0.70, green: 0.68, blue: 0.86, alpha: 1))

y -= 108
draw("不只看见 AI agent 在干嘛，还盯着它有没有真的把活干完。",
     at: CGPoint(x: margin, y: y), size: 30, weight: .semibold,
     color: NSColor(white: 0.88, alpha: 1))
y -= 52
draw("同时跑七八个 Claude Code 会话时，最难受的是：不知道哪个在等你、知道了也切不过去、它停下来那一瞬你正好没在看。",
     at: CGPoint(x: margin, y: y), size: 22, weight: .regular,
     color: NSColor(white: 0.55, alpha: 1))

y -= 60

// ── 各行
for row in rows {
    let slot = slotWidth(row.items.count)
    let height = rowHeight(row)
    y -= height

    for (index, item) in row.items.enumerated() {
        let x = margin + CGFloat(index) * (slot + gap)

        draw(item.title, at: CGPoint(x: x, y: y + height - titleH + 6), size: 27,
             weight: .semibold, color: .white)
        draw(item.note, at: CGPoint(x: x, y: y + height - titleH - noteH + 16), size: 19,
             weight: .regular, color: NSColor(white: 0.56, alpha: 1))

        guard let image = load(item.file) else { continue }
        let size = pixelSize(image)
        let width = min(slot, size.width)
        let imageH = size.height * (width / size.width)
        // 比槽位窄的图在槽位里居中 —— 靠左摆会让右边空出一大块，
        // 看起来像排版塌了而不像留白。
        let inset = (slot - width) / 2
        // 图靠行底对齐：一行里两张不等高时，底对齐比顶对齐整齐得多。
        var rect = CGRect(x: x + inset, y: y, width: width, height: imageH)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            // 深色截图压在深色底上会糊，给一圈极淡的描边把边界收住。
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 26,
                          color: CGColor(gray: 0, alpha: 0.55))
            ctx.draw(cg, in: rect)
            ctx.restoreGState()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.09))
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
    y -= rowGap
}

// ── 尾
draw("完全开源 · MIT · 原生 Swift · 零第三方依赖 · 530 个测试",
     at: CGPoint(x: margin, y: 74), size: 22, weight: .medium,
     color: NSColor(white: 0.62, alpha: 1))
draw("github.com/gulugulu-cn/vibe-foreman",
     at: CGPoint(x: margin, y: 34), size: 24, weight: .semibold,
     color: NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.98, alpha: 1))

NSGraphicsContext.restoreGraphicsState()

// 底部那道渐变线，和社交预览图一致。
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
print("已生成 \(outURL.path)（\(Int(W))×\(Int(totalH))）")
