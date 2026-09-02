import XCTest
@testable import HubProjects

/// 全新安装（projects.yaml 还不存在）时的登记路径。
///
/// 实机背景（issue #1）：仓库克隆在 `~/Documents/code/` 之外的全新机器上，
/// 「添加目录」和「扫描」点了毫无反应 —— `append` 遇到不存在的文件直接
/// return，`addExisting` 却照样返回 true，UI 层又把返回值丢掉。
/// 三层全静默，表现成"按钮是坏的"。
final class ProjectStoreBootstrapTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("projboot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// issue #1 的最小复现：yaml 刻意不建。
    /// 修复前的输出是 true / false / 0 —— 谎报成功、没落盘、列表没变。
    @MainActor
    func testAddExistingCreatesYamlWhenFileIsMissing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // 父目录也不存在 —— 全新机器上 Application Support/claude-hub 就是这样。
        let yaml = root.appendingPathComponent("nested/projects.yaml")
        let store = ProjectStore(yamlURL: yaml, pinURL: nil)
        store.load()

        let dir = root.appendingPathComponent("some-project", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertTrue(store.addExisting(path: dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: yaml.path), "yaml 没被创建")
        XCTAssertEqual(store.projects.map(\.name), ["some-project"])
    }

    /// 真写不进去时必须如实返回 false —— 不能再谎报成功。
    @MainActor
    func testAddExistingReportsWriteFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // 把"父目录"造成一个普通文件，createDirectory 和写入都会失败。
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let yaml = blocker.appendingPathComponent("projects.yaml")

        let store = ProjectStore(yamlURL: yaml, pinURL: nil)
        store.load()

        let dir = root.appendingPathComponent("some-project", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertFalse(store.addExisting(path: dir.path))
        XCTAssertTrue(store.projects.isEmpty)
    }

    /// 文件存在但没有顶格 `projects:` 键：直接追加的条目会变成没有父键的
    /// 孤儿，解析器整段忽略 —— 追加前必须把键补上，且原有内容一字不丢。
    @MainActor
    func testAppendSuppliesMissingProjectsKey() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let yaml = root.appendingPathComponent("projects.yaml")
        try "scan_dirs:\n  - ~/Documents/code\n".write(to: yaml, atomically: true, encoding: .utf8)

        let store = ProjectStore(yamlURL: yaml, pinURL: nil)
        store.load()

        let dir = root.appendingPathComponent("orphan-check", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertTrue(store.addExisting(path: dir.path))
        XCTAssertEqual(store.projects.map(\.name), ["orphan-check"], "条目成了孤儿，没被解析出来")

        let text = try String(contentsOf: yaml, encoding: .utf8)
        XCTAssertTrue(text.contains("scan_dirs:"), "原有内容被弄丢了")
    }

    /// 没有任何已知数据文件时，写入目标必须落到 Application Support ——
    /// app 自己的数据目录，而不是 `candidateURLs.first` 那个
    /// 「仓库大概克隆在 ~/Documents/code 下」的假设（issue #1 的附带问题）。
    @MainActor
    func testWriteTargetFallsBackToApplicationSupport() {
        let store = ProjectStore(yamlURL: nil, pinURL: nil)
        XCTAssertTrue(
            store.writeTargetURL?.path
                .hasSuffix("Library/Application Support/claude-hub/projects.yaml") ?? false,
            "回落目标应是 Application Support，实际：\(store.writeTargetURL?.path ?? "nil")"
        )
    }
}
