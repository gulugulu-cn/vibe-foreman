import XCTest
@testable import HubCore
@testable import HubUI

/// 小人的**解剖学**回归。
///
/// 起因是一个真实缺陷：`waiting` 状态用挥手姿势，`bodyRows` 在肩膀那行画了
/// 举起来的右手，而 `laptopRows` 仍然把两只手都画在笔记本两侧 ——
/// 同一个人有了两只右手。而 waiting 恰恰是最需要被看清的状态。
///
/// 像素画的错误肉眼很难在 32pt 下发现（这个是用户在 48pt 的详情卡上才看出来的），
/// 但在字符网格上是可以精确断言的。
final class SpriteAnatomyTests: XCTestCase {

    private let styles = 0..<SpriteCharacter.styleCount

    /// 皮肤色像素的坐标。手和脸都是皮肤色，所以按行区间区分。
    private func skinPixels(in rows: [String], rowRange: Range<Int>) -> [(x: Int, y: Int)] {
        var out: [(Int, Int)] = []
        for y in rowRange where y < rows.count {
            for (x, char) in Array(rows[y]).enumerated() where char == "f" {
                out.append((x, y))
            }
        }
        return out
    }

    /// 手只可能出现在最外侧两列（x = 0、1、14、15）——
    /// 中间的皮肤色都是脸。
    private func hands(in rows: [String]) -> [(x: Int, y: Int)] {
        skinPixels(in: rows, rowRange: 9..<16).filter { $0.x <= 1 || $0.x >= 14 }
    }

    // MARK: - 每侧最多一只手

    func testWavingHasExactlyOneHandPerSide() {
        for style in styles {
            for step in 0..<4 {
                let rows = SpriteLibrary.rows(style: style, pose: .waving(step: step))
                let found = hands(in: rows)
                let left = found.filter { $0.x <= 1 }
                let right = found.filter { $0.x >= 14 }

                XCTAssertLessThanOrEqual(
                    right.count, 1,
                    "挥手时右手被画了 \(right.count) 只（发型 \(style) 第 \(step) 帧）"
                )
                XCTAssertLessThanOrEqual(
                    left.count, 1,
                    "挥手时左手被画了 \(left.count) 只（发型 \(style) 第 \(step) 帧）"
                )
                XCTAssertEqual(right.count, 1, "挥手的那只手不见了")
            }
        }
    }

    func testEveryPoseHasAtMostOneHandPerSide() {
        let poses: [SpriteLibrary.Pose] = [
            .typing(step: 0), .typing(step: 1), .typing(step: 2), .typing(step: 3),
            .command(step: 0), .command(step: 3),
            .waving(step: 0), .waving(step: 1),
            .resting,
            .yawning(step: 0), .yawning(step: 1),
        ]
        for style in styles {
            for pose in poses {
                let rows = SpriteLibrary.rows(style: style, pose: pose)
                let found = hands(in: rows)
                XCTAssertLessThanOrEqual(
                    found.filter { $0.x <= 1 }.count, 1, "左手多画了：\(pose) 发型 \(style)"
                )
                XCTAssertLessThanOrEqual(
                    found.filter { $0.x >= 14 }.count, 1, "右手多画了：\(pose) 发型 \(style)"
                )
            }
        }
    }

    // MARK: - 网格完整性

    /// 必须正好 16 行 × 16 列。
    ///
    /// 这条曾经真的挡下过 640 个越界：`laptopRows` 一度产出 14 格宽的行。
    func testGridIsAlwaysSixteenBySixteen() {
        let poses: [SpriteLibrary.Pose] = [
            .typing(step: 0), .typing(step: 3), .command(step: 2),
            .waving(step: 0), .waving(step: 1), .resting, .yawning(step: 1),
        ]
        for style in styles {
            for pose in poses {
                let rows = SpriteLibrary.rows(style: style, pose: pose)
                XCTAssertEqual(rows.count, 16, "行数不对：\(pose) 发型 \(style)")
                for (i, row) in rows.enumerated() {
                    XCTAssertEqual(
                        row.count, 16, "第 \(i) 行宽度不对：\(pose) 发型 \(style)"
                    )
                }
            }
        }
    }

    /// 眼睛是这套画法里最值钱的两个像素 —— 有眼睛是个人，没眼睛是个色块。
    /// 任何非闭眼姿势都必须有它们。
    func testOpenEyedPosesKeepTheirEyes() {
        for style in styles {
            let rows = SpriteLibrary.rows(style: style, pose: .typing(step: 0))
            let eyeCount = rows.reduce(0) { $0 + $1.filter { $0 == "e" }.count }
            XCTAssertGreaterThanOrEqual(eyeCount, 2, "发型 \(style) 的眼睛丢了")
        }
    }
}
