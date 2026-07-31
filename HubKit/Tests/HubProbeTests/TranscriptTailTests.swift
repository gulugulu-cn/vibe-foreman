import XCTest
@testable import HubProbe

final class TranscriptTailTests: XCTestCase {

    private var tempDir: URL!
    private var projects: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hubkit-transcript-\(UUID().uuidString)", isDirectory: true)
        projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 造数据

    private func assistant(_ text: String, at stamp: String, apiError: Bool = false) -> String {
        let payload: [String: Any] = [
            "type": "assistant",
            "timestamp": stamp,
            "isApiErrorMessage": apiError,
            "message": ["content": [["type": "text", "text": text]]],
        ]
        return line(payload)
    }

    private func userMessage(_ text: String, at stamp: String) -> String {
        line(["type": "user", "timestamp": stamp, "message": ["content": text]])
    }

    /// 工具结果回填 —— 它也长成 `type: "user"`，但**不是**用户说的话。
    private func toolResult(at stamp: String) -> String {
        line([
            "type": "user", "timestamp": stamp,
            "toolUseResult": ["stdout": "ok"],
            "message": ["content": [["type": "tool_result", "content": "ok"]]],
        ])
    }

    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    @discardableResult
    private func writeTranscript(
        cwd: String, sessionId: String, lines: [String]
    ) throws -> URL {
        let dir = projects.appendingPathComponent(
            TranscriptReader.encode(cwd: cwd), isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionId).jsonl")
        try Data(lines.joined().utf8).write(to: file)
        return file
    }

    private func reader(tailBytes: Int = 64 << 10) -> TranscriptReader {
        TranscriptReader(projectsDirectory: projects, tailBytes: tailBytes)
    }

    // MARK: - API 错误

    func testApiErrorAtTailIsDetected() throws {
        try writeTranscript(cwd: "/tmp/proj", sessionId: "s1", lines: [
            userMessage("跑起来", at: "2026-07-27T06:00:00.000Z"),
            assistant("好的，开始", at: "2026-07-27T06:10:00.000Z"),
            assistant(
                "API Error: Connection closed mid-response. The response above may be incomplete.",
                at: "2026-07-27T06:29:44.882Z", apiError: true
            ),
        ])

        let tail = try XCTUnwrap(reader().read(cwd: "/tmp/proj", sessionId: "s1"))
        XCTAssertTrue(tail.endedWithApiError)
        XCTAssertEqual(
            tail.lastAssistantText,
            "API Error: Connection closed mid-response. The response above may be incomplete."
        )
    }

    /// 报错之后重试成功了 —— **不能**再报警。
    /// 这是"取最后一条 assistant"这个设计要保证的核心行为。
    func testApiErrorFollowedByRecoveryIsNotReported() throws {
        try writeTranscript(cwd: "/tmp/proj", sessionId: "s2", lines: [
            assistant("API Error: Connection closed mid-response.",
                      at: "2026-07-27T06:29:44.882Z", apiError: true),
            assistant("重试成功，继续干活", at: "2026-07-27T06:31:00.000Z"),
        ])

        let tail = try XCTUnwrap(reader().read(cwd: "/tmp/proj", sessionId: "s2"))
        XCTAssertFalse(tail.endedWithApiError)
        XCTAssertEqual(tail.lastAssistantText, "重试成功，继续干活")
    }

    // MARK: - 真实用户消息 vs 工具结果

    /// 本机实测某会话里真实用户消息 41 条、工具结果 1645 条。
    /// 不区分的话"用户回应过了吗"这个判据会被工具结果彻底污染。
    func testToolResultsDoNotCountAsUserMessages() throws {
        try writeTranscript(cwd: "/tmp/proj", sessionId: "s3", lines: [
            userMessage("开始吧", at: "2026-07-27T06:00:00.000Z"),
            toolResult(at: "2026-07-27T06:05:00.000Z"),
            toolResult(at: "2026-07-27T06:06:00.000Z"),
            assistant("干完了", at: "2026-07-27T06:07:00.000Z"),
        ])

        let tail = try XCTUnwrap(reader().read(cwd: "/tmp/proj", sessionId: "s3"))
        let expected = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse("2026-07-27T06:00:00.000Z")
        XCTAssertEqual(tail.lastUserMessageAt, expected)
    }

    // MARK: - 只读尾部

    /// 大文件只读尾部：前面塞一大堆内容，断言读到的是**最后**那条，
    /// 且窗口远小于文件本身。
    func testOnlyReadsTail() throws {
        var lines: [String] = []
        for i in 0..<4000 {
            lines.append(assistant(String(repeating: "填充\(i)", count: 20),
                                   at: "2026-07-27T05:00:00.000Z"))
        }
        lines.append(assistant("最后一条", at: "2026-07-27T06:00:00.000Z"))
        let url = try writeTranscript(cwd: "/tmp/big", sessionId: "s4", lines: lines)

        let size = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertGreaterThan(size, 512 << 10, "测试样本本身要够大才有意义")

        let tail = try XCTUnwrap(reader(tailBytes: 8 << 10).read(url: url))
        XCTAssertEqual(tail.lastAssistantText, "最后一条")
    }

    /// 窗口切在行中间时，残缺的首行必须被丢掉 —— 否则会解析出半截内容。
    func testPartialFirstLineIsDropped() throws {
        let lines = [
            assistant(String(repeating: "长内容", count: 500), at: "2026-07-27T05:00:00.000Z"),
            assistant("完整的最后一条", at: "2026-07-27T06:00:00.000Z"),
        ]
        let url = try writeTranscript(cwd: "/tmp/partial", sessionId: "s5", lines: lines)

        // 窗口刻意开得比第一条小，保证切在它中间。
        let tail = try XCTUnwrap(reader(tailBytes: 300).read(url: url))
        XCTAssertEqual(tail.lastAssistantText, "完整的最后一条")
    }

    /// 尾部窗口里一条 assistant 都没有时要自动扩大窗口重试，
    /// 否则一个超大的工具结果就能让整个探针失明。
    func testWindowGrowsWhenNoAssistantFound() throws {
        var lines = [assistant("被巨型工具结果埋住的回复", at: "2026-07-27T05:00:00.000Z")]
        lines.append(contentsOf: (0..<200).map { _ in toolResult(at: "2026-07-27T06:00:00.000Z") })
        let url = try writeTranscript(cwd: "/tmp/buried", sessionId: "s6", lines: lines)

        let tail = try XCTUnwrap(reader(tailBytes: 256).read(url: url))
        XCTAssertEqual(tail.lastAssistantText, "被巨型工具结果埋住的回复")
    }

    // MARK: - 定位

    func testEncodeMatchesObservedRule() {
        // 本机真实样本：空格和 @ 都变成 -，`/@` 连着产生 `--`
        XCTAssertEqual(
            TranscriptReader.encode(cwd: "/Users/dev/Library/Application Support/@agentx/desktop"),
            "-Users-dev-Library-Application-Support--agentx-desktop"
        )
        XCTAssertEqual(
            TranscriptReader.encode(cwd: "/Users/dev/Documents/code/claude-hub"),
            "-Users-dev-Documents-code-claude-hub"
        )
    }

    /// 编码规则猜错时，要能按 sessionId 在整个 projects 下精确兜底。
    /// 带 `.` 和 `_` 的路径正是规则区分不出来的那一类。
    func testLocateFallsBackToSessionIdScan() throws {
        let dir = projects.appendingPathComponent("完全对不上的目录名", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(assistant("在这儿", at: "2026-07-27T06:00:00.000Z").utf8)
            .write(to: dir.appendingPathComponent("s7.jsonl"))

        let tail = try XCTUnwrap(
            reader().read(cwd: "/tmp/a_b.c/whatever", sessionId: "s7")
        )
        XCTAssertEqual(tail.lastAssistantText, "在这儿")
    }

    func testMissingTranscriptReturnsNil() {
        XCTAssertNil(reader().read(cwd: "/tmp/nope", sessionId: "missing"))
    }
}
