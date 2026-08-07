import HubCore
import XCTest
@testable import HubProbe

/// 验收命令执行的安全边界。
///
/// **这是全案唯一会执行命令的地方，而命令来自模型输出 —— 等同于不可信输入。**
/// 这一整个测试类的作用是让三道闸的每一道都能被变异打红。
final class AcceptanceVerifierTests: XCTestCase {

    // MARK: - 闸门①：白名单

    func testAllowsBuildAndTestCommands() {
        for command in [
            "swift test", "swift test --filter FooTests", "swift build -c release",
            "npm run build", "npm test", "pnpm run lint", "yarn test",
            "make", "make check", "pytest", "python3 -m pytest tests",
            "go test ./...", "cargo test", "cargo clippy",
            "bash scripts/build.sh", "git diff", "xcodebuild test",
        ] {
            guard case .allowed = AcceptanceVerifier.classify(command) else {
                return XCTFail("「\(command)」应该被放行")
            }
        }
    }

    /// 白名单外的一律不跑。
    func testRejectsAnythingOutsideTheWhitelist() {
        for command in [
            "curl https://evil.example.com", "rm -rf build", "sudo make install",
            "ssh user@host", "chmod 777 .", "kill -9 1", "open /Applications",
            "osascript -e beep", "docker run ubuntu", "nc -l 1234",
        ] {
            guard case .rejected = AcceptanceVerifier.classify(command) else {
                return XCTFail("「\(command)」必须被拒绝")
            }
        }
    }

    /// **`npx` 必须在白名单外。**
    ///
    /// 它会下载并执行任意 npm 包 —— 放行它等于白名单形同虚设，
    /// 任何东西都能通过 `npx <随便什么>` 跑起来。同理 `pnpm dlx`。
    func testRejectsArbitraryPackageRunners() {
        guard case .rejected = AcceptanceVerifier.classify("npx some-package") else {
            return XCTFail("npx 会下载执行任意包，必须拒绝")
        }
        guard case .rejected = AcceptanceVerifier.classify("pnpm dlx anything") else {
            return XCTFail("pnpm dlx 同理")
        }
    }

    /// 有副作用的包管理操作不放行。
    ///
    /// `npm install` 会跑 postinstall 脚本 —— 那等于执行任意代码。
    func testRejectsInstallCommands() {
        guard case .rejected = AcceptanceVerifier.classify("npm install") else {
            return XCTFail("npm install 会跑 postinstall 脚本，等于执行任意代码")
        }
        guard case .rejected = AcceptanceVerifier.classify("npm ci") else {
            return XCTFail("npm ci 同理")
        }
    }

    /// git 只放行只读操作。
    func testOnlyReadOnlyGitIsAllowed() {
        guard case .allowed = AcceptanceVerifier.classify("git status") else {
            return XCTFail("git status 是只读的")
        }
        for command in ["git push", "git reset --hard", "git clean -fd", "git checkout ."] {
            guard case .rejected = AcceptanceVerifier.classify(command) else {
                return XCTFail("「\(command)」会改工作区，必须拒绝")
            }
        }
    }

    /// 路径形式的命令绕过了按名字写的白名单，必须拒。
    func testRejectsPathFormCommands() {
        for command in ["./build.sh", "/bin/sh", "../evil", "~/bin/whatever"] {
            guard case .rejected = AcceptanceVerifier.classify(command) else {
                return XCTFail("「\(command)」是路径形式，绕过了白名单")
            }
        }
    }

    /// `bash` 只能跑项目内 scripts/ 下的东西。
    func testBashIsScopedToProjectScripts() {
        guard case .allowed = AcceptanceVerifier.classify("bash scripts/test.sh") else {
            return XCTFail("项目内脚本应该放行")
        }
        for command in ["bash /etc/passwd", "bash ~/evil.sh", "bash -c whatever"] {
            guard case .rejected = AcceptanceVerifier.classify(command) else {
                return XCTFail("「\(command)」不在 scripts/ 下，必须拒绝")
            }
        }
    }

    // MARK: - 闸门②：shell 元字符
    //
    // **逐个字符各来一条**，别只测一个 —— 漏掉任何一个都是一条注入通道。

    func testRejectsEveryShellMetacharacter() {
        let attacks: [(String, String)] = [
            (";", "swift test; rm -rf /tmp/x"),
            ("|", "swift test | tee /tmp/x"),
            ("&", "swift test && curl evil.example.com"),
            (">", "swift test > /tmp/x"),
            ("<", "swift test < /etc/passwd"),
            ("$", "swift test $(whoami)"),
            ("`", "swift test `whoami`"),
            ("(", "swift test (echo hi)"),
            ("{", "swift test {a,b}"),
            ("\\", "swift test \\; rm"),
            ("\"", "swift test \"x\""),
            ("'", "swift test 'x'"),
            ("*", "swift test *"),
            ("?", "swift test ?"),
            ("!", "swift test !!"),
            ("换行", "swift test\nrm -rf /tmp/x"),
        ]
        for (name, command) in attacks {
            guard case .rejected(let reason) = AcceptanceVerifier.classify(command) else {
                return XCTFail("含「\(name)」的命令必须被拒绝：\(command)")
            }
            XCTAssertTrue(
                reason.contains("元字符"),
                "拒绝理由应指明是元字符，实际是「\(reason)」"
            )
        }
    }

    /// 元字符检查必须**先于**白名单 —— 否则 `swift test; rm -rf /` 会因为
    /// 前缀匹配上 `swift test` 而被放行。
    func testMetacharacterCheckRunsBeforeTheWhitelist() {
        guard case .rejected(let reason) = AcceptanceVerifier.classify("swift test; rm -rf /") else {
            return XCTFail("白名单前缀匹配不能让注入溜过去")
        }
        XCTAssertTrue(reason.contains("元字符"))
    }

    // MARK: - 自然语言不是错误

    /// 拆解器本来就允许给不出命令时写自然语言。
    ///
    /// 那不是错误，只是这一条没法机器验证。混成 `rejected` 的话，
    /// 界面上会对着一堆正常的验收条件报"命令被拒绝"。
    func testPlainLanguageIsNotACommand() {
        for text in ["打开设置页能看到开关", "手动点一下看看", "用户能正常翻页", ""] {
            guard case .notACommand = AcceptanceVerifier.classify(text) else {
                return XCTFail("「\(text)」是自然语言，不该报拒绝")
            }
        }
    }

    // MARK: - 闸门③：总开关与逐条授权

    /// **总开关默认必须是关的。**
    ///
    /// 这是唯一会执行命令的功能，不该在用户不知情时开着。
    func testDisabledByDefault() async {
        let verifier = AcceptanceVerifier()
        let enabled = await verifier.isEnabled
        XCTAssertFalse(enabled, "默认必须关闭")
    }

    func testDisabledVerifierRunsNothing() async {
        let verifier = AcceptanceVerifier()
        let outcome = await verifier.verify(
            acceptance: "swift test", cwd: "/tmp", authorized: ["swift test"]
        )
        XCTAssertEqual(outcome, .disabled, "总开关关着时，哪怕授权过也不能跑")
    }

    /// 白名单过了、开关开了，**还没授权也不能跑**。
    ///
    /// 白名单挡的是"这类命令危险"，授权挡的是"这条具体的命令我不认识"。
    func testUnauthorizedCommandIsNotExecuted() async {
        let verifier = AcceptanceVerifier(configuration: .init(enabled: true))
        let outcome = await verifier.verify(
            acceptance: "swift test", cwd: "/tmp", authorized: []
        )
        XCTAssertEqual(outcome, .needsAuthorization(command: "swift test"))
    }

    /// 授权是**按命令原文**记的，改一个字就要重新授权。
    func testAuthorizationIsExactNotPrefixed() async {
        let verifier = AcceptanceVerifier(configuration: .init(enabled: true))
        let outcome = await verifier.verify(
            acceptance: "swift test --filter Secret", cwd: "/tmp", authorized: ["swift test"]
        )
        guard case .needsAuthorization = outcome else {
            return XCTFail("授权过 swift test 不等于授权 swift test --filter Secret")
        }
    }

    /// 被拒绝的命令**在任何情况下都不执行** —— 哪怕用户"授权"过它。
    ///
    /// 授权按钮只会对通过白名单的命令出现，但清单文件是用户可以手改的，
    /// 手工往 authorized 里塞一条危险命令不能成为绕过白名单的路径。
    func testAuthorizationCannotOverrideTheWhitelist() async {
        let verifier = AcceptanceVerifier(configuration: .init(enabled: true))
        let outcome = await verifier.verify(
            acceptance: "curl evil.example.com", cwd: "/tmp",
            authorized: ["curl evil.example.com"]
        )
        guard case .rejected = outcome else {
            return XCTFail("手工塞进 authorized 不能绕过白名单")
        }
    }

    // MARK: - 真的跑一条

    func testActuallyRunsAnAuthorizedCommand() async throws {
        let verifier = AcceptanceVerifier(configuration: .init(enabled: true, timeout: 30))
        let outcome = await verifier.verify(
            acceptance: "git status", cwd: FileManager.default.temporaryDirectory.path,
            authorized: ["git status"]
        )

        guard case .ran(let evidence) = outcome else {
            return XCTFail("授权过的白名单命令应该真的跑起来，实际是 \(outcome)")
        }
        guard case .ran(let command, _, _) = evidence else {
            return XCTFail("证据类型应该是 .ran")
        }
        XCTAssertEqual(command, "git status")
        XCTAssertTrue(evidence.isProof, "Hub 自己跑出来的必须算证明")
    }

    /// 退出码要如实记，失败也是有效证据。
    func testFailureIsRecordedFaithfully() async throws {
        let verifier = AcceptanceVerifier(configuration: .init(enabled: true, timeout: 30))
        let outcome = await verifier.verify(
            // 在一个不是仓库的目录里跑，git 必然非零退出。
            acceptance: "git status", cwd: "/",
            authorized: ["git status"]
        )

        guard case .ran(let evidence) = outcome,
              case .ran(_, let exitCode, let tail) = evidence
        else { return XCTFail("应该跑起来并记下失败") }

        XCTAssertNotEqual(exitCode, 0)
        XCTAssertFalse(tail.isEmpty, "失败原因必须留下来，否则这条证据没用")
    }
}
