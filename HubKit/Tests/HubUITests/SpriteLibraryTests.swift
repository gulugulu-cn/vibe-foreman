import HubCore
import XCTest
@testable import HubUI

/// 守像素小人的网格完整性和形象稳定性。
///
/// 这两类问题在界面上都**不会报错**，只会显示成"有点歪"或"怎么又换发色了"，
/// 只能靠断言挡住。
final class SpriteLibraryTests: XCTestCase {

    private let statuses: [SessionStatus] = [.busy, .waiting, .shell, .idle, .unknown]

    /// 真实量级的 seed，外加整数边界。
    ///
    /// 生产里的 seed 是 `SpriteSeed.stable(sessionId)`，量级接近 `Int.max`。
    /// 边界值单列出来是因为 `abs(Int.min)` 会 trap，而 `magnitude` 不会。
    private var realisticSeeds: [Int] {
        [
            SpriteSeed.stable("8ba8f1c1-6b3d-4e2a-9c11-2f7d0a1b3c4d"),
            SpriteSeed.stable("claude-hub-swiftui-rewrite"),
            SpriteSeed.stable(""),
            Int.max,
            Int.min,
            0,
            -1,
        ]
    }

    // MARK: - 网格

    /// 每一帧都必须正好 16 行 × 16 列。
    ///
    /// 图是分段拼装的（发型 + 脸 + 身体 + 笔记本），少一行会让笔记本掉出画面，
    /// 某行少一格会让整个人歪掉 —— 而 Canvas 只会安静地少画几个方块。
    func testEveryFrameIsSixteenBySixteen() {
        for status in statuses {
            for style in 0..<SpriteCharacter.styleCount {
                for pose in poses {
                    let rows = SpriteLibrary.rows(style: style, pose: pose)
                    XCTAssertEqual(
                        rows.count, 16,
                        "style \(style) / \(pose) 的行数不是 16"
                    )
                    for (index, row) in rows.enumerated() {
                        XCTAssertEqual(
                            row.count, 16,
                            "style \(style) / \(pose) 第 \(index) 行是 \(row.count) 格：\(row)"
                        )
                    }
                }
            }
            // 走一遍真实入口。
            //
            // **seed 必须用真实量级的值。** 这个测试原来喂的是 `tick * 7919`
            // 这种小整数，于是漏掉了一个会让 app 一显示小人就闪退的整数溢出：
            // 真实 seed 来自 FNV 哈希（接近 Int.max），代码里 `abs(seed) * 37`
            // 直接溢出 trap。测试的输入不真实 = 测试没在测东西。
            for tick in 0..<200 {
                for seed in realisticSeeds {
                    let frame = SpriteLibrary.frame(for: status, tick: tick, seed: seed)
                    XCTAssertFalse(frame.runs.isEmpty, "\(status) 在 tick \(tick) 画了个空帧")
                    for run in frame.runs {
                        XCTAssertLessThanOrEqual(run.x + run.width, 16)
                        XCTAssertLessThan(run.y, 16)
                    }
                }
            }
        }
    }

    private var poses: [SpriteLibrary.Pose] {
        var all: [SpriteLibrary.Pose] = [.resting]
        for step in 0..<4 {
            all.append(.typing(step: step))
            all.append(.command(step: step))
            all.append(.waving(step: step))
        }
        for step in 0..<3 { all.append(.yawning(step: step)) }
        return all
    }

    func testMicroFramesAreEightByEight() {
        for status in statuses {
            for tick in 0..<50 {
                for seed in realisticSeeds {
                    let frame = SpriteLibrary.micro(for: status, tick: tick, seed: seed)
                    XCTAssertFalse(frame.runs.isEmpty)
                    for run in frame.runs {
                        XCTAssertLessThanOrEqual(run.x + run.width, 8, "micro 越界")
                        XCTAssertLessThan(run.y, 8)
                    }
                }
            }
        }
    }

    /// 每一帧都要有眼睛。
    ///
    /// 眼睛是这套画法里最值钱的两个像素 —— 有眼睛是个人，没眼睛是个色块。
    /// 拼装逻辑改坏时最先丢的就是它。
    func testEveryFrameHasEyes() {
        for style in 0..<SpriteCharacter.styleCount {
            for pose in poses {
                let frame = SpriteFrame(SpriteLibrary.rows(style: style, pose: pose))
                XCTAssertTrue(
                    frame.runs.contains { $0.ink == .eye },
                    "style \(style) / \(pose) 没有眼睛"
                )
            }
        }
    }

    // MARK: - 形象稳定性

    /// **同一个 sessionId 必须永远长同一个样，跨进程也是。**
    ///
    /// Swift 的 `String.hashValue` 每次进程启动都加盐，用它派生形象的话
    /// 每次重开 app 所有人的发色衣服都会换一遍 ——
    /// "记住橙头发那个是 acme-admin"这件事就不成立了。
    func testSeedIsStableAcrossRuns() {
        // 空串的种子是 FNV-1a 的初始偏移量。这个值变了就说明哈希实现被换掉了，
        // 而那意味着所有用户的会话形象会集体重排。
        XCTAssertEqual(
            SpriteSeed.stable(""),
            Int(UInt64(0xcbf2_9ce4_8422_2325) % UInt64(Int.max))
        )
        XCTAssertEqual(
            SpriteSeed.stable("8ba8f1c1-0000-4000-8000-000000000000"),
            SpriteSeed.stable("8ba8f1c1-0000-4000-8000-000000000000")
        )
        XCTAssertNotEqual(SpriteSeed.stable("a"), SpriteSeed.stable("b"))
        XCTAssertGreaterThanOrEqual(SpriteSeed.stable("任意会话"), 0)
    }

    func testSameSessionAlwaysGetsSameLook() {
        let seed = SpriteSeed.stable("fixed-session-id")
        let first = SpriteCharacter(seed: seed, status: .busy)
        let second = SpriteCharacter(seed: seed, status: .busy)
        XCTAssertEqual(first.hair, second.hair)
        XCTAssertEqual(first.shirt, second.shirt)
        XCTAssertEqual(first.skin, second.skin)
        XCTAssertEqual(first.style, second.style)
    }

    /// 状态变化只该影响明暗，不该换脸。
    func testStatusChangesDimNotIdentity() {
        let seed = SpriteSeed.stable("session")
        let busy = SpriteCharacter(seed: seed, status: .busy)
        let idle = SpriteCharacter(seed: seed, status: .idle)
        XCTAssertEqual(busy.style, idle.style)
        XCTAssertGreaterThan(busy.dim, idle.dim, "idle 应该更暗")
    }

    /// 不同会话要能被区分开 —— 全撞成同一个形象就失去意义了。
    func testDifferentSessionsSpreadAcrossLooks() {
        var looks = Set<String>()
        for index in 0..<40 {
            let seed = SpriteSeed.stable("session-\(index)")
            let character = SpriteCharacter(seed: seed, status: .busy)
            looks.insert("\(character.hair)|\(character.shirt)|\(character.style)")
        }
        XCTAssertGreaterThan(looks.count, 20, "40 个会话只有 \(looks.count) 种形象，区分度不够")
    }
}
