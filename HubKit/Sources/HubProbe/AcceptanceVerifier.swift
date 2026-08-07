import Foundation
import HubCore

/// 一次验证的结果。
public enum VerificationOutcome: Sendable, Equatable {
    /// 真跑了。证据里带命令原文、退出码、输出尾部。
    case ran(Evidence)
    /// 命令不在白名单里，或含 shell 元字符。**不执行。**
    case rejected(reason: String)
    /// 命令合法但用户还没授权过。**不执行。**
    case needsAuthorization(command: String)
    /// 总开关关着。
    case disabled
    /// 验收条件是自然语言，没有可执行形式 —— 只能人工看。
    case notExecutable
}

/// 命令的静态检查结论。
public enum CommandCheck: Sendable, Equatable {
    case allowed([String])          // 拆好的 argv
    case rejected(String)           // 理由
    case notACommand                // 自然语言
}

/// **Hub 自己执行验收命令并捕获输出。**
///
/// ## 为什么执行者必须是 Hub
///
/// 让 Claude 跑完再把结果转述给 Hub，就又回到了「说说而已」—— 转述那一步
/// 正是失真发生的地方。实测见过一次：我谎报"已实现自动执行验收命令"，
/// 旁路复核看到 `case ran(command:exitCode:)` 这个**枚举声明**就判了通过，
/// 而没有任何代码产生它。读代码判断不了功能是否真的能用，只有跑一遍能。
///
/// ## 安全边界（三道闸，缺一不可）
///
/// 验收命令来自**模型输出**，等同于不可信输入。这是全案唯一会执行命令的地方。
///
/// 1. **白名单**：只放行项目内的构建/测试类命令，前缀对不上一律不跑；
/// 2. **拒绝 shell 元字符**：不做转义，直接拒。配合 `Shell.run` 走 execve
///    数组参数（不是 `sh -c`），命令注入在结构上不成立；
/// 3. **默认关闭 + 逐条授权**：总开关默认 off，开启后每条新命令首次执行前
///    要用户在界面上点「允许」。
///
/// 不做沙箱、不做超时之外的资源限制 —— 那是过度设计。三道闸把风险压在
/// 「用户自己本来就会敲的命令」这个范围内。
public actor AcceptanceVerifier {

    public struct Configuration: Sendable {
        /// **默认关闭。** 这是唯一会执行命令的功能，不该在用户不知情时开着。
        public var enabled: Bool
        /// 单条命令的上限。构建和测试都可能跑几分钟。
        public var timeout: TimeInterval
        /// 留存的输出尾部长度。尾部比头部有用 —— 失败原因和统计都在最后。
        public var tailLimit: Int

        public init(
            enabled: Bool = false, timeout: TimeInterval = 300, tailLimit: Int = 4_000
        ) {
            self.enabled = enabled
            self.timeout = timeout
            self.tailLimit = tailLimit
        }
    }

    private var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func update(configuration: Configuration) {
        self.configuration = configuration
    }

    public var isEnabled: Bool { configuration.enabled }

    // MARK: - 闸门①：白名单
    //
    // 每一项是「命令的前若干个词」。argv 的开头必须完全匹配其中一项。
    //
    // 刻意排除的：
    // - `npx` / `pnpm dlx` —— 它们会下载并执行任意包，等于白名单形同虚设；
    // - `npm install` / `ci` —— 有副作用（改 node_modules、可能跑 postinstall 脚本）；
    // - `git` 的写操作 —— 只留 diff / status / log 这些只读的。

    static let whitelist: [[String]] = [
        ["swift", "test"], ["swift", "build"],
        ["npm", "run"], ["npm", "test"],
        ["pnpm", "run"], ["pnpm", "test"],
        ["yarn", "run"], ["yarn", "test"],
        ["make"],
        ["pytest"], ["python3", "-m", "pytest"],
        ["go", "test"], ["go", "build"], ["go", "vet"],
        ["cargo", "test"], ["cargo", "build"], ["cargo", "clippy"],
        ["bash", "scripts/"],
        ["git", "diff"], ["git", "status"], ["git", "log"],
        ["xcodebuild", "test"], ["xcodebuild", "build"],
    ]

    // MARK: - 闸门②：shell 元字符
    //
    // 一个都不许有。**不做转义，直接拒** —— 转义是个永远补不完的名单，
    // 而这里完全不需要这些字符：白名单里全是 `cmd sub --flag value` 的形状。
    //
    // 配合 Shell.run 走 execve 数组参数（不是 sh -c），即使漏了某个字符，
    // 它也只会被当成一个普通的参数字面量传下去，不会被解释。
    // 两道一起上，不二选一。

    static let forbidden: Set<Character> = [
        ";", "|", "&", ">", "<", "$", "`", "(", ")", "{", "}",
        "\n", "\r", "\\", "\"", "'", "*", "?", "!",
    ]

    /// 静态检查一条验收条件。**不执行任何东西。**
    public static func classify(_ acceptance: String) -> CommandCheck {
        let trimmed = acceptance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notACommand }

        // ⚠️ 这一步**必须在白名单之前**。放到后面的话 `swift test | tee /tmp/x`
        // 会因为前缀匹配上 `swift test` 而被放行 —— 变异测试实测过。
        if let bad = trimmed.first(where: { forbidden.contains($0) }) {
            return .rejected("含 shell 元字符「\(bad)」")
        }

        let argv = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let head = argv.first else { return .notACommand }

        // 绝对路径 / 相对路径的可执行文件一律不放行 —— 白名单是按命令名写的，
        // `./build.sh` 这种绕过了它。要跑就写成 `bash scripts/build.sh`。
        guard !head.contains("/") else {
            return .rejected("不接受路径形式的命令，请写成白名单内的形式")
        }

        // 看起来完全不像命令名（中文描述、"打开设置页能看到开关"）→ 交给人工。
        //
        // 注意这里返回的是 `.notACommand` 而不是 `.rejected`：拆解器本来就允许
        // 给不出可执行形式时写自然语言，那不是错误，只是这一条没法机器验证。
        // 混成 rejected 的话，界面上会对着一堆正常的验收条件报"命令被拒绝"。
        let nameCharacters: (Character) -> Bool = {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
        }
        guard head.allSatisfy(nameCharacters) else { return .notACommand }

        for shape in whitelist where matches(argv: argv, shape: shape) {
            return .allowed(argv)
        }
        return .rejected("「\(head)」不在白名单里")
    }

    /// argv 的开头是否匹配白名单的某一项。
    ///
    /// 末尾带 `/` 的项（`["bash", "scripts/"]`）表示这一段只要**以它开头**即可，
    /// 用来允许 `bash scripts/任意.sh` 而不放行 `bash /etc/任意`。
    static func matches(argv: [String], shape: [String]) -> Bool {
        guard argv.count >= shape.count else { return false }
        for (index, expected) in shape.enumerated() {
            let actual = argv[index]
            if expected.hasSuffix("/") {
                guard actual.hasPrefix(expected) else { return false }
            } else {
                guard actual == expected else { return false }
            }
        }
        return true
    }

    // MARK: - 执行

    /// 跑一条验收命令。
    ///
    /// - Parameter authorized: 用户已经点过「允许」的命令原文集合。
    public func verify(
        acceptance: String?, cwd: String, authorized: Set<String>
    ) -> VerificationOutcome {
        guard let acceptance else { return .notExecutable }
        guard configuration.enabled else { return .disabled }

        switch Self.classify(acceptance) {
        case .notACommand:
            return .notExecutable
        case .rejected(let reason):
            return .rejected(reason: reason)
        case .allowed(let argv):
            let command = argv.joined(separator: " ")
            // 闸门③：白名单过了也要用户点过头。白名单挡的是"这类命令危险"，
            // 授权挡的是"这条具体的命令我不认识"。
            guard authorized.contains(command) else {
                return .needsAuthorization(command: command)
            }
            return execute(argv: argv, cwd: cwd, command: command)
        }
    }

    private func execute(argv: [String], cwd: String, command: String) -> VerificationOutcome {
        guard let executable = Self.locate(argv[0]) else {
            return .rejected(reason: "找不到 \(argv[0])")
        }

        let result = Shell.run(
            executable,
            Array(argv.dropFirst()),
            timeout: configuration.timeout,
            environment: Self.environment(cwd: cwd),
            // 必须在项目目录里跑，否则 swift test 找不到 Package.swift。
            currentDirectory: cwd
        )

        let combined = (result.stdout + result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = combined.count <= configuration.tailLimit
            ? combined
            : "…（只留尾部）\n" + String(combined.suffix(configuration.tailLimit))

        return .ran(.ran(command: command, exitCode: result.status, tail: tail))
    }

    /// 找可执行文件。
    ///
    /// **不能靠 PATH**：Hub 是 GUI app，从 launchd 起，PATH 只有
    /// `/usr/bin:/bin:/usr/sbin:/sbin` —— homebrew 装的 node / cargo 全都不在。
    /// 同 `StallJudge.locateClaude` 的理由。
    static func locate(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [
            "/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin",
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin",
            "/usr/local/go/bin",
        ]
        for directory in directories {
            let path = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// 给子进程一个像样的 PATH。
    ///
    /// npm 找 node、cargo 找 rustc 都靠 PATH，光定位到 npm 本身不够。
    static func environment(cwd: String) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = [
            "/usr/local/bin", "/opt/homebrew/bin", "\(home)/.local/bin",
            "\(home)/.cargo/bin", "\(home)/.bun/bin", "/usr/local/go/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        return [
            "PATH": path,
            // 语言环境：launchd 给的环境里没有 LANG，一些工具会按 ASCII 处理
            // 输出，撞上中文就炸（video-digest 那边真踩过一模一样的坑）。
            "LANG": "en_US.UTF-8",
            "PWD": cwd,
        ]
    }
}
