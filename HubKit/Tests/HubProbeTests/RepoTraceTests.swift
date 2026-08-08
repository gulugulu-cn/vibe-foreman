import XCTest
@testable import HubProbe

/// 去仓库里找一条要点有没有留下痕迹。
///
/// 这一层补的是最大的缺口：旁路复核只在它自报做完时才跑，
/// **它压根不提的事情没有任何东西会去查**。
/// 三份训练素材发过去两小时一个都没接，系统里没有任何机制发现，是用户先问的。
final class RepoTraceTests: XCTestCase {

    // MARK: - 关键词提取

    /// 引号里的名字是最可靠的搜索词。
    func testPicksQuotedNames() {
        XCTAssertTrue(
            RepoTrace.keywords(from: "把「product-viability」接进 market-researcher")
                .contains("product-viability")
        )
    }

    /// 路径和带连字符的标识符 —— skill / 目录名的典型形态。
    func testPicksPathLikeTokens() {
        let words = RepoTrace.keywords(from: "接入 ecommerce-product-selection 的 6 个 skill")
        XCTAssertTrue(words.contains("ecommerce-product-selection"))
    }

    func testPicksFilePaths() {
        let words = RepoTrace.keywords(from: "改 config/default-agents/leader/prompt.md")
        XCTAssertTrue(words.contains { $0.contains("default-agents") })
    }

    /// **挑不出就返回空，别硬凑。**
    ///
    /// 拿「训练」「验证」这种词去搜什么都能命中，会把「有痕迹」这个信号
    /// 稀释成噪音 —— 那比不查更糟，因为它会让人以为查过了。
    func testReturnsNothingWhenNoSearchableToken() {
        XCTAssertTrue(RepoTrace.keywords(from: "训练要落到实处，不能只写报告").isEmpty)
        XCTAssertTrue(RepoTrace.keywords(from: "多测几轮").isEmpty)
    }

    /// 版本号不能当关键词 —— 搜出来全是噪音。
    func testIgnoresVersionNumbers() {
        XCTAssertFalse(RepoTrace.keywords(from: "发布 0.2.101 镜像").contains("0.2.101"))
    }

    /// 太短的点分标识符（a.b）不要。
    func testIgnoresTinyTokens() {
        XCTAssertTrue(RepoTrace.keywords(from: "看 a.b 那个").isEmpty)
    }

    func testDeduplicatesAndCaps() {
        let text = "「a-one」「a-one」「b-two」「c-three」「d-four」「e-five」"
        let words = RepoTrace.keywords(from: text)
        XCTAssertLessThanOrEqual(words.count, 3, "搜太多次不值")
        XCTAssertEqual(Set(words).count, words.count, "要去重")
    }

    // MARK: - 真仓库里找痕迹

    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repotrace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            _ = Shell.run("/usr/bin/git", ["-C", repo.path] + args, timeout: 10)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func commit(file: String, message: String) throws {
        let url = repo.appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "x".write(to: url, atomically: true, encoding: .utf8)
        _ = Shell.run("/usr/bin/git", ["-C", repo.path, "add", "-A"], timeout: 10)
        _ = Shell.run("/usr/bin/git", ["-C", repo.path, "commit", "-qm", message], timeout: 10)
    }

    /// 文件名里有 = 有痕迹。
    func testFindsTraceInFileNames() throws {
        try commit(file: "skills/product-viability/SKILL.md", message: "add skill")

        XCTAssertTrue(RepoTrace.hasTrace("product-viability", cwd: repo.path))
    }

    /// commit 信息里提到 = 有痕迹（哪怕文件名没有）。
    func testFindsTraceInCommitMessage() throws {
        try commit(file: "a.txt", message: "train: 接入 ecommerce-product-selection")

        XCTAssertTrue(RepoTrace.hasTrace("ecommerce-product-selection", cwd: repo.path))
    }

    /// **一点痕迹都没有 —— 这才是要报的信号。**
    func testReportsNoTrace() throws {
        try commit(file: "a.txt", message: "别的活")

        XCTAssertFalse(RepoTrace.hasTrace("marketing-competitor-analysis", cwd: repo.path))
        XCTAssertEqual(
            RepoTrace.missingTrace(
                for: "接入 marketing-competitor-analysis 的 skill", cwd: repo.path
            ),
            "marketing-competitor-analysis"
        )
    }

    /// **有一个关键词命中就算有动静。** 宁可漏报，不可误告 ——
    /// 误告一次，用户就不信这个信号了。
    func testAnyMatchingKeywordCountsAsTouched() throws {
        try commit(file: "skills/product-viability/SKILL.md", message: "add")

        XCTAssertNil(
            RepoTrace.missingTrace(
                for: "把「product-viability」接进 marketing-competitor-analysis", cwd: repo.path
            ),
            "有一个关键词有痕迹就不该报"
        )
    }

    /// 挑不出关键词时返回 nil（判不了），不是"没痕迹"。
    func testUnsearchableItemIsNotReported() throws {
        try commit(file: "a.txt", message: "x")

        XCTAssertNil(RepoTrace.missingTrace(for: "训练要落到实处", cwd: repo.path))
    }

    /// 不是 git 仓库就别判。
    func testNonRepositoryIsNotJudged() {
        XCTAssertNil(
            RepoTrace.missingTrace(
                for: "接入 some-missing-skill", cwd: FileManager.default.temporaryDirectory.path
            )
        )
    }
}
