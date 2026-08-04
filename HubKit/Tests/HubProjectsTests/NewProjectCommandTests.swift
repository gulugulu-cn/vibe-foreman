import XCTest
@testable import HubProjects

final class NewProjectCommandTests: XCTestCase {

    private func command(
        name: String = "demo", remote: NewProjectCommand.Remote = .privateRepo,
        deny: Bool = true, desc: String = ""
    ) -> NewProjectCommand {
        var cmd = NewProjectCommand()
        cmd.name = name
        cmd.remote = remote
        cmd.applyDenyGuard = deny
        cmd.descriptionText = desc
        return cmd
    }

    func testDefaultArgumentsArePrivateWithDeny() {
        let args = command().arguments(scriptPath: "/s.sh")
        XCTAssertEqual(args, ["/s.sh", "demo", "--dir", "~/Documents/code", "--private"])
    }

    func testPublicAndLocalOnlyMapToFlags() {
        XCTAssertTrue(command(remote: .publicRepo).arguments(scriptPath: "/s.sh").contains("--public"))
        XCTAssertTrue(command(remote: .localOnly).arguments(scriptPath: "/s.sh").contains("--no-remote"))
    }

    func testNoDenyAndDescriptionAreForwarded() {
        let args = command(deny: false, desc: " 描述 ").arguments(scriptPath: "/s.sh")
        XCTAssertTrue(args.contains("--no-deny"))
        // 描述要 trim 后原样传给脚本（脚本侧再写进 README）。
        XCTAssertEqual(args.suffix(2), ["--desc", "描述"])
    }

    func testNameIsTrimmedBeforeUse() {
        XCTAssertEqual(command(name: " demo \n").trimmedName, "demo")
        XCTAssertNil(command(name: " demo ").validationError)
    }

    /// 这些名字直接拼进路径和 gh 仓名，必须在 UI 层拦下。
    func testValidationRejectsUnsafeNames() {
        XCTAssertNotNil(command(name: "").validationError)
        XCTAssertNotNil(command(name: "a b").validationError)
        XCTAssertNotNil(command(name: "a/b").validationError)
        XCTAssertNotNil(command(name: "-rf").validationError)
    }

    func testScriptURLPrefersYAMLNeighborWhenPresent() {
        // yaml 指向仓库根下的 projects.yaml 时，应找同仓库的 scripts/new-project.sh。
        let hubYAML = URL(fileURLWithPath: NSString(
            string: "~/Documents/code/claude-hub/projects.yaml"
        ).expandingTildeInPath)
        let url = NewProjectCommand.scriptURL(near: hubYAML)
        XCTAssertTrue(url.path.hasSuffix("claude-hub/scripts/new-project.sh"))
    }
}
