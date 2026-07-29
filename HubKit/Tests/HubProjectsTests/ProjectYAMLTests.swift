import XCTest
@testable import HubProjects

final class ProjectYAMLTests: XCTestCase {

    /// 真实样本，结构抄自本机 projects.yaml。
    private let sample = """
    scan_dirs:
      - ~/Documents/code
      - ~/Documents/code/shopify

    projects:
      - name: acme-erp
        aliases: [acme-admin, erp, 后台]
        path: ~/Documents/code/acme-admin
        description: "示例管理后台 (GIN-VUE-ADMIN)"
        tags: [vue, gin, docker]
      - name: claude-hub
        path: ~/Documents/code/claude-hub
        description: "调度中心"
    """

    func testParsesRealSample() {
        let projects = ProjectYAML.parse(sample)
        XCTAssertEqual(projects.count, 2)

        let erp = projects[0]
        XCTAssertEqual(erp.name, "acme-erp")
        XCTAssertEqual(erp.path, "~/Documents/code/acme-admin")
        XCTAssertEqual(erp.aliases, ["acme-admin", "erp", "后台"])
        XCTAssertEqual(erp.description, "示例管理后台 (GIN-VUE-ADMIN)")
        XCTAssertEqual(erp.tags, ["vue", "gin", "docker"])
    }

    /// scan_dirs 段落里的 `- ~/...` 长得很像项目条目，必须跳过。
    func testScanDirsSectionIsIgnored() {
        let projects = ProjectYAML.parse(sample)
        XCTAssertFalse(projects.contains { $0.name.contains("Documents") })
    }

    func testTildeExpansion() {
        let project = Project(name: "x", path: "~/code/x")
        XCTAssertTrue(project.expandedPath.hasPrefix("/"))
        XCTAssertFalse(project.expandedPath.contains("~"))
    }

    func testAbsolutePathUnchanged() {
        XCTAssertEqual(Project(name: "x", path: "/opt/x").expandedPath, "/opt/x")
    }

    func testCommentsAndBlankLinesIgnored() {
        let text = """
        # 这是注释
        projects:

          # 另一条注释
          - name: a
            path: /tmp/a
        """
        let projects = ProjectYAML.parse(text)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "a")
    }

    /// 缺 path 的条目直接丢弃，不能造出一个指向空路径的项目。
    func testEntryWithoutPathIsDropped() {
        let text = """
        projects:
          - name: broken
          - name: ok
            path: /tmp/ok
        """
        let projects = ProjectYAML.parse(text)
        XCTAssertEqual(projects.map(\.name), ["ok"])
    }

    func testInlineNameOnDashLine() {
        let text = """
        projects:
          - name: inline
            path: /tmp/inline
        """
        XCTAssertEqual(ProjectYAML.parse(text).first?.name, "inline")
    }

    func testEmptyInputYieldsNoProjects() {
        XCTAssertTrue(ProjectYAML.parse("").isEmpty)
        XCTAssertTrue(ProjectYAML.parse("projects:").isEmpty)
    }
}

final class GitStatusParsingTests: XCTestCase {

    func testCleanRepoWithUpstream() {
        let info = GitStatus.parse("""
        # branch.oid abc123
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """)
        XCTAssertEqual(info.branch, "main")
        XCTAssertTrue(info.isClean)
        XCTAssertTrue(info.hasUpstream)
        XCTAssertEqual(info.ahead, 0)
        XCTAssertEqual(info.behind, 0)
    }

    func testDirtyRepoCountsEveryChangeLine() {
        let info = GitStatus.parse("""
        # branch.head feature/x
        # branch.upstream origin/feature/x
        # branch.ab +3 -1
        1 .M N... 100644 100644 100644 aaa bbb file1.swift
        1 M. N... 100644 100644 100644 ccc ddd file2.swift
        ? untracked.txt
        """)
        XCTAssertEqual(info.branch, "feature/x")
        XCTAssertEqual(info.changeCount, 3)
        XCTAssertEqual(info.ahead, 3)
        XCTAssertEqual(info.behind, 1)
        XCTAssertFalse(info.isClean)
    }

    /// 没有上游的分支不该显示 ahead/behind —— 那两个数字没有意义。
    func testBranchWithoutUpstream() {
        let info = GitStatus.parse("""
        # branch.head local-only
        """)
        XCTAssertEqual(info.branch, "local-only")
        XCTAssertFalse(info.hasUpstream)
    }

    func testDetachedHeadHasNoBranch() {
        let info = GitStatus.parse("# branch.head (detached)")
        XCTAssertNil(info.branch)
    }
}

final class UsageEncodingTests: XCTestCase {

    /// 编码规则必须和 Claude Code 完全一致，否则统计会全部落空。
    func testDirectoryEncodingMatchesClaudeCode() {
        XCTAssertEqual(
            UsageStats.encodeDirectoryName(for: "/Users/dev/Documents/code/claude-hub"),
            "-Users-dev-Documents-code-claude-hub"
        )
    }

    func testNonAsciiBecomesDash() {
        XCTAssertEqual(UsageStats.encodeDirectoryName(for: "/tmp/项目"), "-tmp---")
    }

    func testDotsAndUnderscoresBecomeDash() {
        XCTAssertEqual(UsageStats.encodeDirectoryName(for: "/a/b.c_d"), "-a-b-c-d")
    }
}

final class LaunchModeTests: XCTestCase {

    func testCommandsMatchRustImplementation() {
        XCTAssertEqual(LaunchMode.claude.command(sessionId: nil), "claude")
        XCTAssertEqual(
            LaunchMode.claudeSkipPermissions.command(sessionId: nil),
            "claude --dangerously-skip-permissions"
        )
        XCTAssertEqual(LaunchMode.resumeLast.command(sessionId: nil), "claude --continue")
        XCTAssertEqual(LaunchMode.resumePick.command(sessionId: nil), "claude --resume")
        XCTAssertNil(LaunchMode.terminal.command(sessionId: nil))
    }

    func testResumeSessionQuotesId() {
        XCTAssertEqual(
            LaunchMode.resumeSession.command(sessionId: "abc-123"),
            "claude --resume 'abc-123'"
        )
    }

    /// sessionId 来自文件内容，理论上可控 —— 引号必须转义，不能拼出注入。
    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(shellQuote("a; rm -rf /"), "'a; rm -rf /'")
    }
}
