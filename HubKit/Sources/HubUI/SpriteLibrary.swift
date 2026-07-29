import HubCore
import SwiftUI

/// 一帧像素画，已按水平游程合并成矩形列表。
///
/// 合并很关键：16×16 的图有 256 个格子，但按行合并连续同色像素之后只剩 40–60 个矩形。
/// 9 个小人 × 50 矩形 × 12fps ≈ 5400 矩形/秒，对 Canvas 是微不足道的量。
struct SpriteFrame {
    struct Run {
        let x: Int
        let y: Int
        let width: Int
        let ink: SpriteInk
    }

    let runs: [Run]

    /// 从字符网格构造。字符含义见 `SpriteInk`。
    init(_ rows: [String]) {
        var out: [Run] = []
        for (y, row) in rows.enumerated() {
            let chars = Array(row)
            var x = 0
            while x < chars.count {
                guard let ink = SpriteInk(character: chars[x]) else {
                    x += 1
                    continue
                }
                var width = 1
                while x + width < chars.count, chars[x + width] == chars[x] { width += 1 }
                out.append(Run(x: x, y: y, width: width, ink: ink))
                x += width
            }
        }
        runs = out
    }
}

/// 画笔。
///
/// ## 为什么从"状态染色的单色剪影"改成"有肤色和衣服的角色"
///
/// 旧版每个小人整体用状态色染，四个 busy 会话画出来一模一样 —— 只是四个蓝色块。
/// 更糟的是轮廓用的是近黑（`0.04,0.05,0.06`），而岛本身也是近黑，
/// 轮廓完全溶进背景，剩下的就真的只是一坨颜色。
///
/// 现在：**形象归角色，状态归屏幕**。
/// - 发色 / 肤色 / 衣服由 `sessionId` 决定且**永远不变** ——
///   你会记住"橙头发那个是 acme-admin"，这是单色剪影给不了的辨识度；
/// - 状态由笔记本屏幕的光色表达，配合下方的状态色条和状态点，一样一眼可读。
enum SpriteInk {
    case outline    // '#'
    case hair       // 'h'
    case hairShade  // 'H'
    case skin       // 'f'
    case skinShade  // 'F'
    case eye        // 'e'
    case shirt      // 's'
    case shirtShade // 'S'
    case laptop     // 'L'
    case laptopEdge // 'l'
    case glow       // 'g'

    init?(character: Character) {
        switch character {
        case "#": self = .outline
        case "h": self = .hair
        case "H": self = .hairShade
        case "f": self = .skin
        case "F": self = .skinShade
        case "e": self = .eye
        case "s": self = .shirt
        case "S": self = .shirtShade
        case "L": self = .laptop
        case "l": self = .laptopEdge
        case "g": self = .glow
        default: return nil   // '.' 和空格都是透明
        }
    }

    func color(character: SpriteCharacter, status: SessionStatus) -> Color {
        // idle 的人要"退到后面去"，但**不能变成灰色幽灵** —— 那是旧版最难看的地方。
        // 保留原本的色相，只压饱和与亮度，读起来像"灯关了"而不是"这个人不见了"。
        let dim = character.dim
        switch self {
        case .outline: return Color(red: 0.05, green: 0.06, blue: 0.08).opacity(0.95)
        case .hair: return character.hair.opacity(dim)
        case .hairShade: return character.hair.opacity(dim * 0.62)
        case .skin: return character.skin.opacity(dim)
        case .skinShade: return character.skin.opacity(dim * 0.72)
        case .eye: return Color(red: 0.09, green: 0.10, blue: 0.13).opacity(dim)
        case .shirt: return character.shirt.opacity(dim)
        case .shirtShade: return character.shirt.opacity(dim * 0.66)
        // 笔记本压暗一档：它是配角。太亮的话整张图会被一块灰白色块主导，
        // 而人脸才是要被认出来的那部分。
        case .laptop: return Color(white: 0.66).opacity(dim)
        case .laptopEdge: return Color(white: 0.40).opacity(dim)
        // 屏幕的光是状态的载体。idle 时它就是暗的 —— 屏幕熄了，正是"没在干活"。
        case .glow:
            return status == .idle || status == .unknown
                ? Color(white: 0.34).opacity(dim)
                : IslandTheme.color(for: status)
        }
    }
}

/// 跨进程稳定的哈希。
///
/// **不能用 Swift 的 `String.hashValue`** —— 它每次进程启动都会重新加盐，
/// 同一个 sessionId 在两次运行里得到的值不同。用它做形象派生的话，
/// 每次重开 app 所有人的发色衣服都会换一遍，"记住橙头发那个是 acme-admin"
/// 这件事根本立不住。
///
/// FNV-1a：够散、够快、结果只取决于输入。
enum SpriteSeed {
    static func stable(_ value: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        // 收到 Int 的正数区间，调用方普遍在做 `abs(seed) % n`。
        return Int(hash % UInt64(Int.max))
    }
}

/// 一个会话的固定形象。
///
/// 全部由 `sessionId` 派生，所以**同一个会话永远长同一个样**，
/// 换机器、重启 app、`--resume` 都不变（sessionId 是 UUID，不是 PID）。
struct SpriteCharacter {
    let hair: Color
    let skin: Color
    let shirt: Color
    let style: Int      // 发型
    let dim: Double

    /// 发色。有意做得饱和度高、彼此拉开 —— 这是区分会话的主要通道。
    private static let hairPalette: [Color] = [
        Color(red: 0.96, green: 0.62, blue: 0.20),   // 橙
        Color(red: 0.36, green: 0.24, blue: 0.18),   // 深棕
        Color(red: 0.95, green: 0.83, blue: 0.42),   // 金
        Color(red: 0.72, green: 0.25, blue: 0.28),   // 酒红
        Color(red: 0.20, green: 0.22, blue: 0.28),   // 黑
        Color(red: 0.55, green: 0.42, blue: 0.72),   // 紫
    ]

    private static let skinPalette: [Color] = [
        Color(red: 0.98, green: 0.84, blue: 0.72),
        Color(red: 0.91, green: 0.73, blue: 0.58),
        Color(red: 0.76, green: 0.56, blue: 0.42),
        Color(red: 0.55, green: 0.38, blue: 0.28),
    ]

    private static let shirtPalette: [Color] = [
        Color(red: 0.29, green: 0.55, blue: 0.86),   // 蓝
        Color(red: 0.30, green: 0.68, blue: 0.52),   // 绿
        Color(red: 0.86, green: 0.42, blue: 0.44),   // 珊瑚
        Color(red: 0.42, green: 0.44, blue: 0.52),   // 灰蓝
        Color(red: 0.88, green: 0.66, blue: 0.30),   // 芥黄
        Color(red: 0.52, green: 0.40, blue: 0.66),   // 紫
    ]

    static let styleCount = 4

    init(seed: Int, status: SessionStatus) {
        // 三个属性各用 seed 的不同段，避免"发色一样的人衣服也一样"。
        // 用 magnitude 而不是 abs：`abs(Int.min)` 会 trap。
        let base = Int(seed.magnitude % UInt(Int.max))
        hair = Self.hairPalette[base % Self.hairPalette.count]
        skin = Self.skinPalette[(base / 7) % Self.skinPalette.count]
        shirt = Self.shirtPalette[(base / 13) % Self.shirtPalette.count]
        style = (base / 31) % Self.styleCount
        dim = (status == .idle || status == .unknown) ? 0.55 : 1.0
    }
}

/// 像素小人素材库。
///
/// art 用字符串字面量写在代码里，不做成 PNG 资产：可以 diff、可以 code review、
/// 改一个像素不用重新导出，还能按角色调色。
///
/// 构图参考了"人在笔记本后面"这个经典画法：头 + 肩 + 挡在身前的笔记本，
/// 双手从两侧露出来。好处是**上半身占满画面**，16×16 这么小的网格里
/// 五官才有地方放；画全身的话头只有 4px，怎么画都是一坨。
enum SpriteLibrary {

    /// 取某状态在某个时钟 tick 下应该显示的帧。
    ///
    /// - Parameter seed: 用 sessionId 的 hash。它同时决定**形象**（发色、衣服、发型）
    ///   和**动作相位** —— 9 个人整齐划一地同时敲键盘会很诡异。
    static func frame(for status: SessionStatus, tick: Int, seed: Int) -> SpriteFrame {
        let style = SpriteCharacter(seed: seed, status: status).style
        let phase = tick + Int(seed.magnitude % 4)

        switch status {
        case .busy:
            return SpriteFrame(rows(style: style, pose: .typing(step: phase / 2 % 4)))
        case .shell:
            return SpriteFrame(rows(style: style, pose: .command(step: phase / 2 % 4)))
        case .waiting:
            // waiting **不错峰**：需要用户行动的状态就该整齐地一起挥手，
            // 那是刻意制造的注意力抓取。
            return SpriteFrame(rows(style: style, pose: .waving(step: tick / 2 % 4)))
        case .idle, .unknown:
            return SpriteFrame(rows(style: style, pose: idlePose(tick: tick, seed: seed)))
        }
    }

    /// idle 是**状态机**而不是纯循环，这是省电的关键。
    ///
    /// 9 个会话里通常 6–7 个是 idle。如果它们都按 6fps 循环，前面为了省电做的
    /// 一切都白费了。所以 idle 平时是静止的闭眼，每 8–14 秒才打一次哈欠，
    /// 而且按 seed 错峰 —— 6 个人同时打哈欠会很出戏。
    private static func idlePose(tick: Int, seed: Int) -> Pose {
        let clock = 12                          // 主时钟 12 tick = 1 秒
        // **先取模再运算。** 这里曾经写成 `abs(seed) * 37`，而真实的 seed 来自
        // FNV 哈希（量级接近 Int.max），一乘就整数溢出，Swift 直接 trap ——
        // 表现是 app 一显示小人就闪退。任何拿哈希值做算术的地方都要先收进小区间。
        let magnitude = seed.magnitude
        let period = (8 + Int(magnitude % 7)) * clock
        let phase = (tick + Int(magnitude % UInt(period))) % period
        let yawnLength = 2 * clock
        if phase < yawnLength {
            return .yawning(step: (phase * 3) / yawnLength)
        }
        return .resting
    }

    // MARK: - 姿势

    enum Pose {
        case typing(step: Int)
        case command(step: Int)
        case waving(step: Int)
        case resting
        case yawning(step: Int)
    }

    // MARK: - 组装

    /// 把发型、脸、身体、笔记本拼成 16×16。
    ///
    /// 分段拼装而不是给每个状态各写 4 张完整的图：那样是 16 张手写网格，
    /// 改一处（比如笔记本宽一格）要同步改 16 遍，必然漂。
    static func rows(style: Int, pose: Pose) -> [String] {
        var out: [String] = []
        out.append(contentsOf: hairRows(style: style))
        out.append(contentsOf: faceRows(pose: pose))
        out.append(contentsOf: bodyRows(pose: pose))
        out.append(contentsOf: laptopRows(pose: pose))
        // 拼出来必须正好 16 行 —— 少一行会让笔记本贴到画面外。
        return out
    }

    /// 发型（第 0–3 行，含顶上一行留白）。
    ///
    /// 四种，靠**轮廓形状**区分而不只是颜色 —— 缩到 32pt 时形状比颜色更早可辨，
    /// 而且色觉障碍用户也分得出。
    /// 最后一行统一是 10 格宽，好和下面的脸对齐。
    private static func hairRows(style: Int) -> [String] {
        switch style % 4 {
        case 0:   // 齐刘海
            return [
                "................",
                ".....######.....",
                "....#hhhhhh#....",
                "...#hhhhhhhh#...",
            ]
        case 1:   // 侧分
            return [
                "................",
                "....#######.....",
                "...#hhhhhhhh#...",
                "...#hhhHHhhh#...",
            ]
        case 2:   // 蓬松
            return [
                "................",
                "...##h##h##h....",
                "...#hhhhhhhh#...",
                "...#hHhhhhHh#...",
            ]
        default:  // 丸子头
            return [
                ".......##.......",
                "......#hh#......",
                "....#hhhhhh#....",
                "...#hhhhhhhh#...",
            ]
        }
    }

    /// 脸（第 4–8 行）。
    ///
    /// 给了 5 行 —— 初版只给 4 行、笔记本占 7 行，结果脸小得只剩两个点，
    /// 整张图被一块灰色笔记本主导。**这是张人物像，不是张笔记本像。**
    /// 眼睛是这套画法里最值钱的两个像素：有眼睛是个人，没眼睛是个色块。
    private static func faceRows(pose: Pose) -> [String] {
        let closed: Bool
        var mouth = "...#ffffffff#..."
        switch pose {
        case .resting:
            closed = true
        case .yawning(let step):
            closed = true
            // 哈欠张嘴：中间挖成阴影。
            mouth = step >= 1 ? "...#ffFeeFff#..." : "...#ffFFFFff#..."
        default:
            closed = false
        }

        let eyes = closed
            ? "...#feeeeeef#..."      // 闭眼画成一条横线
            : "...#feffffef#..."

        return [
            "...#hffffffh#...",       // 两侧留一点鬓角
            eyes,
            mouth,
            "....#ffffff#....",
            ".....#ffff#.....",       // 下巴收窄
        ]
    }

    /// 肩膀（第 9–10 行）。waving 时右侧多一只挥动的手。
    private static func bodyRows(pose: Pose) -> [String] {
        guard case .waving(let step) = pose else {
            return [
                "..##ssssssss##..",
                ".#ssssssssssss#.",
            ]
        }
        // 手掌左右摆一格，幅度小但在 32pt 下看得出来。
        return [
            step % 2 == 0 ? "..##ssssssss##f." : "..##ssssssss##.f",
            ".#ssssssssssss#.",
        ]
    }

    /// 笔记本（第 9–15 行）。
    ///
    /// 从背面看，所以是一块盖板 + 中间发光的标志 —— 屏幕的光就是状态。
    /// 双手从两侧露出来，敲键盘时上下动一格。
    private static func laptopRows(pose: Pose) -> [String] {
        // 手的位置用**这一段内部的行号**（0…4），不是整图行号 ——
        // 用整图行号的话，上面任何一段增减一行都会让手悄悄跑到别的地方去。
        var hands = (left: 2, right: 2)
        // 发光区占 4 格宽 × 2 行。初版只有 2×1，那点面积根本传达不了状态。
        var glow = "gggg"

        switch pose {
        case .typing(let step):
            // 两只手交替上下，敲键盘的节奏就出来了。
            hands = [(1, 2), (2, 1), (2, 2), (1, 1)][step % 4]
        case .command(let step):
            // 命令行：发光区变成一个左右走的光标，和"敲键盘"最容易区分开。
            glow = ["g...", ".g..", "..g.", "...g"][step % 4]
            hands = (2, 2)
        case .waving, .resting, .yawning:
            hands = (2, 2)
        }

        /// `.` + 左手 + `#` + 盖板 10 格 + `#` + 右手 + `.` = 16 格。
        func lid(_ local: Int, _ core: String) -> String {
            let left = hands.left == local ? "f" : "."
            let right = hands.right == local ? "f" : "."
            return ".\(left)#\(core)#\(right)."
        }

        return [
            "..############..",
            lid(1, "LLL\(glow)LLL"),
            lid(2, "LLL\(glow)LLL"),
            "..#LLLLLLLLLL#..",
            "..#llllllllll#..",
        ]
    }

    // MARK: - 小尺寸

    /// 列表行用的 8×8 简化版。
    ///
    /// 不复用 16×16 缩小：那些 1px 的眼睛、发型细节在 8px 网格上会退化成噪点。
    /// 这里只保留三件事 —— 头发的颜色块、两只眼睛、发光的笔记本。
    /// 这就是 SF Symbols 的光学尺寸思路：小尺寸要的是另一张图，不是同一张缩小。
    static func micro(for status: SessionStatus, tick: Int, seed: Int) -> SpriteFrame {
        let sleeping = status == .idle || status == .unknown
        // 睁眼的会偶尔眨一下；idle 一直闭着。
        // 同样先把 seed 收进小区间：`abs(Int.min)` 会 trap，加法也可能溢出。
        let blink = !sleeping && (tick / 12 + Int(seed.magnitude % 7)) % 7 == 0
        let eyes = (sleeping || blink) ? "#feef#." : "#fefe#."

        return SpriteFrame([
            "..####..",
            ".#hhhh#.",
            ".#Hhhh#.",
            ".\(eyes)",
            "#ssssss#",
            "#LLggLL#",
            "#LLggLL#",
            "#llllll#",
        ])
    }
}
