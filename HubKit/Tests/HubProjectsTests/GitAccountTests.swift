import XCTest
@testable import HubProjects

final class GitAccountTests: XCTestCase {

    // MARK: - gh auth status 解析

    func testParseSingleActiveAccount() {
        let text = """
        github.com
          ✓ Logged in to github.com account anjiacm (keyring)
          - Active account: true
          - Git operations protocol: https
        """
        let accounts = GitAccountParser.parse(text)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.login, "anjiacm")
        XCTAssertEqual(accounts.first?.host, "github.com")
        XCTAssertEqual(accounts.first?.active, true)
    }

    func testParseMultipleAccountsKeepsActiveFlagPerAccount() {
        let text = """
        github.com
          ✓ Logged in to github.com account work-acct (keyring)
          - Active account: true
          ✓ Logged in to github.com account side-acct (keyring)
          - Active account: false
        """
        let accounts = GitAccountParser.parse(text)
        XCTAssertEqual(accounts.map(\.login), ["work-acct", "side-acct"])
        XCTAssertEqual(accounts.map(\.active), [true, false])
    }

    func testParseGarbageYieldsNothing() {
        XCTAssertTrue(GitAccountParser.parse("gh: command not found").isEmpty)
        XCTAssertTrue(GitAccountParser.parse("").isEmpty)
    }

    // MARK: - 仓库列表（NDJSON）

    /// `gh api --paginate --jq` 出的是一行一个对象；坏行要跳过而不是整批失败。
    func testParseRepoLinesSkipsGarbage() {
        let text = """
        {"nameWithOwner":"anjiacm/foo","isPrivate":true}
        not json
        {"nameWithOwner":"some-org/bar","isPrivate":false}

        """
        let repos = GitAccountParser.parseRepoLines(text)
        XCTAssertEqual(repos.map(\.nameWithOwner), ["anjiacm/foo", "some-org/bar"])
        XCTAssertEqual(repos.map(\.isPrivate), [true, false])
    }

    // MARK: - 多账号 / owner 分组

    @MainActor
    func testOwnersGroupReposByOwnerSortedByCount() {
        let store = GitAccountStore(cacheURL: nil)
        store.debugSeed(
            accounts: [GitAccount(host: "github.com", login: "me", active: true)],
            repos: [
                RemoteRepo(nameWithOwner: "org-a/one", isPrivate: true),
                RemoteRepo(nameWithOwner: "org-a/two", isPrivate: true),
                RemoteRepo(nameWithOwner: "me/solo", isPrivate: false),
            ]
        )
        XCTAssertEqual(store.owners.map(\.name), ["org-a", "me"])
        XCTAssertEqual(store.owners.map(\.count), [2, 1])
    }

    /// 每个账号的仓库分开存：切回上一个账号要立刻有列表，不能被覆盖掉。
    @MainActor
    func testReposAreKeptPerAccount() {
        let store = GitAccountStore(cacheURL: nil)
        let a = GitAccount(host: "github.com", login: "work", active: true)
        let b = GitAccount(host: "github.com", login: "side", active: false)
        store.debugSeed(accounts: [a, b], repos: [
            RemoteRepo(nameWithOwner: "work/x", isPrivate: true),
        ])
        store.debugSeed(accounts: [
            GitAccount(host: "github.com", login: "work", active: false),
            GitAccount(host: "github.com", login: "side", active: true),
        ], repos: [RemoteRepo(nameWithOwner: "side/y", isPrivate: false)])

        XCTAssertEqual(store.repos.map(\.nameWithOwner), ["side/y"])
        XCTAssertEqual(store.reposByAccount[a.id]?.map(\.nameWithOwner), ["work/x"])
    }

    // MARK: - 克隆命令

    private func command(repo: String, name: String = "") -> CloneCommand {
        var cmd = CloneCommand()
        cmd.repo = repo
        cmd.nameOverride = name
        return cmd
    }

    /// 三种常见写法都要推得出目录名 —— 推错了会克隆到奇怪的地方。
    func testDerivedNameFromAllRepoForms() {
        XCTAssertEqual(command(repo: "anjiacm/foo").derivedName, "foo")
        XCTAssertEqual(command(repo: "https://github.com/anjiacm/foo.git").derivedName, "foo")
        XCTAssertEqual(command(repo: "git@github.com:anjiacm/foo.git").derivedName, "foo")
        XCTAssertEqual(command(repo: "a/b", name: "custom").derivedName, "custom")
    }

    func testCloneArguments() {
        let args = command(repo: "anjiacm/foo").arguments(scriptPath: "/c.sh")
        XCTAssertEqual(args, ["/c.sh", "anjiacm/foo", "--dir", "~/Documents/code"])
        let named = command(repo: "anjiacm/foo", name: "bar").arguments(scriptPath: "/c.sh")
        XCTAssertEqual(named.suffix(2), ["--name", "bar"])
    }

    func testCloneValidation() {
        XCTAssertNotNil(command(repo: "").validationError)
        XCTAssertNil(command(repo: "anjiacm/foo").validationError)
    }
}
