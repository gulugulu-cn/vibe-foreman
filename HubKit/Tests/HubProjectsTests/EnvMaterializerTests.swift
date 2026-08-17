import XCTest
@testable import HubProjects

/// 物化。这一组里有一半是安全测试。
final class EnvMaterializerTests: XCTestCase {

    private var root: URL!
    private var dir: URL { EnvMaterializer.byProjectDirectory(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-env-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func target(_ name: String, _ body: String) -> EnvMaterializer.Target {
        .init(fileName: name, contents: body)
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private func mtime(_ url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return attrs[.modificationDate] as? Date ?? .distantPast
    }

    // MARK: - 权限

    /// 目录 0700 是真正承重的那道：`.atomic` 先按 umask 建临时文件（0644）再 rename，
    /// 那一瞬间文件是敞开的，只有目录进不去才让这个窗口没有意义。
    func testDirectoryIs700AndFileIs600() throws {
        _ = EnvMaterializer.reconcile(targets: [target("a-00000001.env", "x")], root: root)
        XCTAssertEqual(try mode(root), 0o700)
        XCTAssertEqual(try mode(dir), 0o700)
        XCTAssertEqual(try mode(dir.appendingPathComponent("a-00000001.env")), 0o600)
    }

    /// **连续写两次之后权限仍然要是 0600。**
    ///
    /// 这条不是凑数：`.atomic` 是「写临时文件 → rename」，rename 之后 inode 就换了，
    /// 第一次设的权限跟第二次写出来的文件毫无关系。
    /// 只在创建时 chmod 一次的写法，从第二次改密钥开始就是 0644，而且没有任何症状。
    func testPermissionsSurviveRewrite() throws {
        let name = "a-00000001.env"
        _ = EnvMaterializer.reconcile(targets: [target(name, "v1")], root: root)
        _ = EnvMaterializer.reconcile(targets: [target(name, "v2")], root: root)
        XCTAssertEqual(try mode(dir.appendingPathComponent(name)), 0o600)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8), "v2")
    }

    /// 用户（或者别的工具）把权限改松了，下一次同步要给改回来 —— 但不能因此重写内容。
    func testLoosePermissionsAreTightenedWithoutRewriting() throws {
        let name = "a-00000001.env"
        let url = dir.appendingPathComponent(name)
        _ = EnvMaterializer.reconcile(targets: [target(name, "same")], root: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let before = try mtime(url)

        let outcome = EnvMaterializer.reconcile(targets: [target(name, "same")], root: root)
        XCTAssertEqual(outcome, .alreadyCorrect)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mtime(url), before, "内容没变却重写了文件")
    }

    // MARK: - 幂等

    func testUnchangedContentIsNotRewritten() throws {
        let name = "a-00000001.env"
        _ = EnvMaterializer.reconcile(targets: [target(name, "same")], root: root)
        let before = try mtime(dir.appendingPathComponent(name))

        XCTAssertEqual(EnvMaterializer.reconcile(targets: [target(name, "same")], root: root),
                       .alreadyCorrect)
        XCTAssertEqual(try mtime(dir.appendingPathComponent(name)), before)
    }

    // MARK: - 清理

    /// 取消勾选之后，磁盘上那份密钥必须真的消失。
    /// 留着的话，用户以为已经收回了，实际上路径还在、值还在。
    func testUnboundProjectFileIsRemoved() throws {
        _ = EnvMaterializer.reconcile(targets: [target("a-00000001.env", "x")], root: root)
        let outcome = EnvMaterializer.reconcile(targets: [], root: root)
        XCTAssertEqual(outcome, .installed(written: 0, removed: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a-00000001.env").path))
    }

    /// **用户自己放进这个目录的文件，一个都不许动。**
    ///
    /// 清理逻辑只认 `<slug>-<8位十六进制>.env` 这个形状。
    /// 判宽一点就会去删用户手写的东西 —— 而这个目录里装的都是密钥，删了没处找。
    func testForeignFilesAreNeverTouched() throws {
        _ = EnvMaterializer.reconcile(targets: [target("a-00000001.env", "x")], root: root)
        let mine = dir.appendingPathComponent("mine.env")
        let alsoMine = dir.appendingPathComponent("notes.txt")
        try Data("我自己写的".utf8).write(to: mine)
        try Data("也是我的".utf8).write(to: alsoMine)

        _ = EnvMaterializer.reconcile(targets: [], root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path), "用户自己的 .env 被删了")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alsoMine.path))
    }

    /// 总开关关掉 = 磁盘上一份明文都不留。但仍然只清自己的。
    func testDisabledClearsOnlyOwnFiles() throws {
        _ = EnvMaterializer.reconcile(targets: [
            target("a-00000001.env", "x"), target("b-00000002.env", "y"),
        ], root: root)
        let mine = dir.appendingPathComponent("mine.env")
        try Data("留着".utf8).write(to: mine)

        let outcome = EnvMaterializer.reconcile(targets: [
            target("a-00000001.env", "x"), target("b-00000002.env", "y"),
        ], root: root, enabled: false)
        XCTAssertEqual(outcome, .cleared(removed: 2))
        XCTAssertEqual(EnvMaterializer.materializedFileCount(root: root), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path))
    }

    // MARK: - git 检查

    /// 把 `~/.vibe-foreman` 收进 dotfiles 仓库然后推上 GitHub，是这个功能最坏的结局。
    /// 每一次写盘前都要查，不是启动时查一次 —— 用户完全可能过一阵子才在家目录 `git init`。
    func testRefusesToWriteInsideGitRepository() throws {
        _ = EnvMaterializer.reconcile(targets: [target("a-00000001.env", "x")], root: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        let before = try String(contentsOf: dir.appendingPathComponent("a-00000001.env"), encoding: .utf8)

        let outcome = EnvMaterializer.reconcile(targets: [target("a-00000001.env", "改了")], root: root)
        XCTAssertTrue(outcome.isFailure, "在 git 仓库里照写不误")
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("a-00000001.env"), encoding: .utf8),
            before, "报了错但还是写了"
        )
    }

    /// **`.git` 是个文件也算。** git worktree 和 submodule 的 `.git` 就是一个文本文件，
    /// 只认目录的话，在 worktree 里会判成「不在仓库内」然后照写。
    func testGitFileCountsAsRepository() throws {
        let parent = root.deletingLastPathComponent()
            .appendingPathComponent("vf-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("gitdir: /somewhere/.git/worktrees/x\n".utf8)
            .write(to: parent.appendingPathComponent(".git"))

        let nested = parent.appendingPathComponent("vibe-foreman")
        // 必须真的有东西要写才测得到这条 —— 没东西写又没目录时会提前返回，
        // 那时候本来也没有什么需要保护的。
        let outcome = EnvMaterializer.reconcile(
            targets: [target("a-00000001.env", "x")], root: nested
        )
        XCTAssertTrue(outcome.isFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path), "报了错还是建了目录")
    }

    /// 祖先目录是仓库也算。
    func testAncestorRepositoryIsDetected() throws {
        let repo = root.deletingLastPathComponent()
            .appendingPathComponent("vf-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        let deep = repo.appendingPathComponent("a/b/vibe-foreman")
        let outcome = EnvMaterializer.reconcile(
            targets: [target("a-00000001.env", "x")], root: deep
        )
        XCTAssertTrue(outcome.isFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deep.path), "报了错还是建了目录")
    }

    // MARK: - 认领

    /// 目录里已经有别人的东西就不接管 —— 接管意味着 reconcile 会开始删里面的文件。
    func testRefusesToAdoptNonEmptyForeignDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("别人的".utf8).write(to: root.appendingPathComponent("important.txt"))

        XCTAssertTrue(EnvMaterializer.reconcile(targets: [], root: root).isFailure)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("important.txt").path))
    }

    func testMarkerFilesAreCreated() throws {
        _ = EnvMaterializer.reconcile(targets: [target("a-00000001.env", "x")], root: root)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(EnvMaterializer.ownerMarker).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(EnvMaterializer.spotlightMarker).path))
    }

    func testMaterializedFileCountIgnoresForeignFiles() throws {
        _ = EnvMaterializer.reconcile(targets: [
            target("a-00000001.env", "x"), target("b-00000002.env", "y"),
        ], root: root)
        try Data("x".utf8).write(to: dir.appendingPathComponent("mine.env"))
        XCTAssertEqual(EnvMaterializer.materializedFileCount(root: root), 2)
    }

    /// **没用过这个功能就不该在人家家目录里建东西。**
    ///
    /// 启动时会无条件对一次账（补崩溃时漏掉的删除）。这里要是照常建目录，
    /// 每个装了 app 的人都会凭空多出一个 ~/.vibe-foreman，哪怕他从没打开过密钥页。
    func testNothingToDoCreatesNothing() throws {
        XCTAssertEqual(EnvMaterializer.reconcile(targets: [], root: root), .alreadyCorrect)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// 但目录已经存在时照常对账 —— 那正是「补上漏掉的删除」要干的事。
    func testExistingDirectoryStillGetsReconciled() throws {
        _ = EnvMaterializer.reconcile(targets: [target("a-00000001.env", "x")], root: root)
        XCTAssertEqual(EnvMaterializer.reconcile(targets: [], root: root),
                       .installed(written: 0, removed: 1))
    }
}
