import XCTest
@testable import HubProjects

/// 守用量统计的流式解析和缓存。
///
/// 背景：原实现对每个 jsonl 做 `String(contentsOf:)` 再 `split`，
/// 而 `~/.claude/projects` 实测有 **945 MB / 341 个文件**，
/// 整份读进内存跑不出结果，用量页永远停在 0 —— 用户读到的是"这个功能没做"。
final class UsageStreamingTests: XCTestCase {

    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func scan(_ url: URL) -> FileUsage? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return UsageStats.scanFile(
            url,
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate ?? .distantPast
        )
    }

    // MARK: - 解析正确性

    func testCountsTokensAcrossLines() throws {
        let url = try write([
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"message":{"model":"claude-opus-5","usage":{"input_tokens":3,"cache_read_input_tokens":7,"cache_creation_input_tokens":2,"output_tokens":4}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let stats = try XCTUnwrap(scan(url))
        XCTAssertEqual(stats.messages, 2)
        // 10 + (3 + 7 + 2)：cache 读写都算进入 input。
        XCTAssertEqual(stats.input, 22)
        XCTAssertEqual(stats.output, 9)
        XCTAssertEqual(stats.models, ["claude-opus-5"])
    }

    /// **跨块的那一行不能被切坏。**
    ///
    /// 分块读的关键细节：块边界几乎必然落在某行中间，残留的尾巴必须留到
    /// 下一块开头拼接。写错的话表现是"大文件统计偏低"，而且非常难发现 ——
    /// 数字只是小了一点，不会报错。
    func testHandlesLinesSpanningChunkBoundaries() throws {
        // 每行塞一段长 padding，逼出多个 1 MB 块。
        let padding = String(repeating: "x", count: 200_000)
        var lines: [String] = []
        for index in 0..<20 {
            lines.append(
                #"{"pad":"\#(padding)","message":{"usage":{"input_tokens":\#(index),"output_tokens":1}}}"#
            )
        }
        let url = try write(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let stats = try XCTUnwrap(scan(url))
        XCTAssertEqual(stats.messages, 20, "跨块的行被漏掉或切坏了")
        XCTAssertEqual(stats.input, (0..<20).reduce(0, +))
        XCTAssertEqual(stats.output, 20)
    }

    /// 最后一行没有换行符时也要算进去。
    func testCountsFinalLineWithoutTrailingNewline() throws {
        let url = try write([
            #"{"message":{"usage":{"input_tokens":1,"output_tokens":1}}}"#
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try XCTUnwrap(scan(url)).messages, 1)
    }

    /// 坏行、空行、没有 usage 的行都要安静跳过，不能中断整个文件。
    func testSkipsMalformedAndIrrelevantLines() throws {
        let url = try write([
            "",
            "这不是 json",
            #"{"message":{"content":"没有 usage"}}"#,
            #"{"broken":"usage 出现在这里但结构不对"}"#,
            #"{"message":{"usage":{"input_tokens":5,"output_tokens":2}}}"#,
            "",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let stats = try XCTUnwrap(scan(url))
        XCTAssertEqual(stats.messages, 1)
        XCTAssertEqual(stats.input, 5)
    }

    func testEmptyFileYieldsZeros() throws {
        let url = try write([])
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try XCTUnwrap(scan(url))
        XCTAssertEqual(stats.messages, 0)
        XCTAssertEqual(stats.input, 0)
    }

    // MARK: - 缓存

    /// 缓存的失效判据是 size + mtime。两者都没变就必须命中，
    /// 否则每次打开都要重扫近 1 GB。
    func testCacheRoundTrips() throws {
        let entry = FileUsage(
            size: 123, modified: Date(timeIntervalSince1970: 1_700_000_000),
            messages: 4, input: 100, output: 50, models: ["claude-opus-5"]
        )
        let encoded = try JSONEncoder().encode(["/tmp/a.jsonl": entry])
        let decoded = try JSONDecoder().decode([String: FileUsage].self, from: encoded)

        let restored = try XCTUnwrap(decoded["/tmp/a.jsonl"])
        XCTAssertEqual(restored.size, entry.size)
        XCTAssertEqual(restored.modified, entry.modified)
        XCTAssertEqual(restored.input, entry.input)
        XCTAssertEqual(restored.models, entry.models)
    }

    // MARK: - 范围

    func testRangeCutoffs() {
        XCTAssertNil(UsageRange.all.cutoff)
        XCTAssertNotNil(UsageRange.week7.cutoff)
        XCTAssertNotNil(UsageRange.month30.cutoff)
        // 7 天的截止时间必须比 30 天的晚（窗口更窄）。
        XCTAssertGreaterThan(
            try XCTUnwrap(UsageRange.week7.cutoff),
            try XCTUnwrap(UsageRange.month30.cutoff)
        )
    }
}
