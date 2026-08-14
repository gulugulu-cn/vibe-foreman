import CoreGraphics
import Foundation
import ImageIO

// 把 PNG 裁到「不透明内容」的外接矩形。
//
// 岛是画在一个 640×720 的透明容器窗口里的（这样形态变化时不用改窗口尺寸），
// 直接 `screencapture -l` 截下来四周有大片透明。不裁的话拼进长图里
// 就是一块巨大的空白，看起来像排版塌了。
//
// 阈值取 20 而不是 0：岛有一圈很淡的外发光，按 alpha>0 裁会把那圈
// 几乎看不见的雾也算进来，边距忽大忽小、每张都不一样。

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 1 else {
    FileHandle.standardError.write(Data("用法：crop-alpha.swift <输入.png> [输出.png]\n".utf8))
    exit(1)
}
let input = URL(fileURLWithPath: args[0])
let output = URL(fileURLWithPath: args.count >= 2 ? args[1] : args[0])

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { exit(1) }

let width = image.width
let height = image.height

// 重画一遍进已知布局的缓冲区 —— 直接读 image.dataProvider 拿到的字节序
// 依赖源图的 bitmapInfo，PNG 的排列方式不止一种，猜错就裁在莫名其妙的地方。
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let ctx = pixels.withUnsafeMutableBytes({ raw -> CGContext? in
    CGContext(
        data: raw.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}) else { exit(1) }
ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

let threshold: UInt8 = 20
var minX = width, minY = height, maxX = -1, maxY = -1

for y in 0..<height {
    let row = y * width * 4
    for x in 0..<width where pixels[row + x * 4 + 3] > threshold {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}

guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write(Data("整张都是透明的\n".utf8))
    exit(1)
}

let rect = CGRect(
    x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
)
guard let cropped = image.cropping(to: rect),
      let dest = CGImageDestinationCreateWithURL(
        output as CFURL, "public.png" as CFString, 1, nil
      )
else { exit(1) }

CGImageDestinationAddImage(dest, cropped, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("\(width)×\(height) → \(Int(rect.width))×\(Int(rect.height))")
