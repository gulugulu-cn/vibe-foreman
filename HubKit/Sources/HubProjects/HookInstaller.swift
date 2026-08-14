import Foundation
import HubProbe

/// 自己把 hook 装进 `~/.claude/settings.json`。
///
/// ## 为什么要 app 自己来
///
/// 原来的装法是「拖进应用程序 → **双击 dmg 里的「安装 hook.command」** → 打开 app」。
/// 中间那一步是纯粹的摩擦：它没有任何用户能做的决定，只是把一段脚本跑一遍。
/// 而漏了它的后果是**静默的** —— app 打开了、界面正常、一条事件都收不到，
/// 用户看到的是"这东西装了但没用"。
///
/// 对照过的同类产品把「零配置」当成头号卖点，这一步是我们和它差距最大的地方，
/// 而它恰恰不需要用户参与。
///
/// ## 三条约束
///
/// 1. **只碰自己的那几条。** settings.json 是用户自己的配置文件，里面可能有
///    他手写的 hook。合并时只删「命令里含 `hubctl hook` 或 `hub-hook-`」的条目
///    （那是我们自己的旧版），其余原样保留。
/// 2. **幂等。** 每次启动都跑一遍，内容没变就一个字节都不写 ——
///    否则每次开 app 都在用户的 git 工作区里制造一个 diff。
/// 3. **改之前先备份。** 只在真的要写时备份，且只留一份。
public struct HookInstaller: Sendable {

    public enum Outcome: Sendable, Equatable {
        /// 已经是对的，什么都没做。
        case alreadyCorrect
        /// 装好了 / 修好了。
        case installed(hooks: Int)
        /// 装不了，附原因。**不抛异常**：hook 没装好不该让 app 起不来。
        case failed(String)

        public var isHealthy: Bool {
            switch self {
            case .alreadyCorrect, .installed: return true
            case .failed: return false
            }
        }
    }

    /// 要装的九类 hook。
    ///
    /// **全装，不挑。** 只装用得着的那几类是个诱人的省事做法，但它让
    /// "这一类到底通不通"无从判断 —— 收不到事件时分不清是"没装"还是
    /// "装了但链路断了"。全装上之后设置页的通道健康度才有意义。
    struct HookSpec {
        let event: String
        let argument: String
        /// 阻塞的 hook 要等 Hub 的决策，得有 timeout；非阻塞的走 async。
        let timeout: Int?
    }

    static let specs: [HookSpec] = [
        // ⚠️ SessionStart / UserPromptSubmit 的 stdout 会被 Claude 当成附加 context
        // 注入进对话。hubctl 在这些链路上一个字都不往 stdout 打，
        // async 是第二道保险（异步 hook 的输出会被直接忽略）。
        HookSpec(event: "SessionStart", argument: "sessionstart", timeout: nil),
        HookSpec(event: "UserPromptSubmit", argument: "userprompt", timeout: nil),
        // 90 秒是超时阶梯的最外层，必须大于 hubctl 的 75 秒读超时：
        // Claude 若在 hubctl 输出拒绝之前就把它杀掉，等同于没有输出，
        // 也就是**放行** —— 正好是安全默认值的反面。
        HookSpec(event: "PreToolUse", argument: "pretool", timeout: 90),
        HookSpec(event: "PostToolUse", argument: "posttool", timeout: nil),
        HookSpec(event: "Notification", argument: "notification", timeout: nil),
        // Stop 挡在**每一次收工**前面，Hub 一卡住用户就干等。
        // 判断本身是查内存、毫秒级，这 10 秒纯粹是异常时的上界。
        HookSpec(event: "Stop", argument: "stop", timeout: 10),
        HookSpec(event: "SubagentStop", argument: "subagentstop", timeout: nil),
        HookSpec(event: "PreCompact", argument: "precompact", timeout: nil),
        HookSpec(event: "SessionEnd", argument: "sessionend", timeout: nil),
    ]

    private let settingsURL: URL
    private let binURL: URL
    /// hubctl 的来源。nil = 去 app 包里找。
    ///
    /// 可注入是为了测试：`Bundle.main` 在 xctest 里指向测试宿主，
    /// 真去包里找必然落空。而这段代码会改用户的 settings.json，
    /// **测不到就等于没有护栏**。
    private let sourceOverride: URL?

    public init(settingsURL: URL? = nil, binURL: URL? = nil, source: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.settingsURL = settingsURL
            ?? home.appendingPathComponent(".claude/settings.json")
        self.binURL = binURL ?? home.appendingPathComponent(".local/bin")
        self.sourceOverride = source
    }

    // MARK: - 安装

    @discardableResult
    public func install() -> Outcome {
        guard let source = sourceOverride ?? Self.locateBundledHubctl() else {
            return .failed("找不到 hubctl —— app 包不完整？")
        }
        let hubctl = binURL.appendingPathComponent("hubctl")

        do {
            try syncBinary(from: source, to: hubctl)
        } catch {
            return .failed("装 hubctl 失败：\(error.localizedDescription)")
        }

        do {
            let existing = (try? Data(contentsOf: settingsURL)) ?? Data("{}".utf8)
            let object = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any]
            // 文件坏了就**不动它**。覆盖等于把用户的配置直接删了，
            // 而他可能只是手改时漏了个逗号。
            guard let object else {
                return .failed("\(settingsURL.path) 不是合法 JSON，没有改动它")
            }

            let merged = Self.merge(settings: object, hubctlPath: hubctl.path)
            // **`.sortedKeys` 不是审美，是幂等的前提。**
            //
            // 不加的话 JSONSerialization 的键顺序跟着字典的哈希走、每次都可能不同，
            // 于是下面那个"内容没变就不写"的判断会随机失效 ——
            // 表现是每隔几次启动就在用户的配置文件上留一次无意义的改动。
            //
            // 代价是首次运行会把他的键按字母重排一次。JSON 里键序无语义，
            // 且只发生一次；比"每次启动都可能改文件"划算得多。
            let data = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            var output = data
            output.append(0x0A)   // 结尾换行，和脚本写出来的保持一致

            // 幂等：内容没变就一个字节都不写。
            if output == existing { return .alreadyCorrect }

            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // 只在真的要写时备份，且只留一份 —— 每次启动都攒一个带时间戳的
            // 备份文件，一个月后那个目录就没法看了。
            if !existing.isEmpty, FileManager.default.fileExists(atPath: settingsURL.path) {
                try? existing.write(to: settingsURL.appendingPathExtension("hubbak"))
            }
            try output.write(to: settingsURL, options: .atomic)
            return .installed(hooks: Self.specs.count)
        } catch {
            return .failed("写 settings.json 失败：\(error.localizedDescription)")
        }
    }

    /// 合并 hook 配置。纯函数，测试盯着它。
    ///
    /// 传进来的 settings 原样返回，只改 `hooks` 里我们负责的那几个事件；
    /// 每个事件里也只删自己的旧条目，用户手写的一条不动。
    static func merge(settings: [String: Any], hubctlPath: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for spec in specs {
            let kept = stripOurs(hooks[spec.event] as? [[String: Any]] ?? [])

            var hook: [String: Any] = [
                "type": "command",
                "command": "\(hubctlPath) hook \(spec.argument)",
            ]
            if let timeout = spec.timeout {
                hook["timeout"] = timeout
            } else {
                // async: true 很关键 —— 同步 hook 会让每轮回复结束都被阻塞。
                hook["async"] = true
            }
            hooks[spec.event] = kept + [["hooks": [hook]]]
        }

        settings["hooks"] = hooks
        return settings
    }

    /// 剔掉我们自己装过的条目（含更早的 bash 版），**保留用户手写的**。
    static func stripOurs(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.filter { entry in
            let commands = (entry["hooks"] as? [[String: Any]] ?? [])
                .compactMap { $0["command"] as? String }
            return !commands.contains { $0.contains("hubctl hook") || $0.contains("hub-hook-") }
        }
    }

    // MARK: - hubctl

    /// 把 app 包里的 hubctl 同步到 `~/.local/bin`。
    ///
    /// 每次都比内容再决定要不要拷：升级 app 之后 hook 还指着旧的二进制，
    /// 协议一变就整条链路静默失效 —— 而表现只是"收不到事件"。
    private func syncBinary(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binURL, withIntermediateDirectories: true)

        let incoming = try Data(contentsOf: source)
        if let current = try? Data(contentsOf: destination), current == incoming { return }

        try? fm.removeItem(at: destination)
        try incoming.write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    /// 找 app 包里的 hubctl。
    ///
    /// 开发时是从 `.build` 里直接跑的，那时候 `Bundle.main` 指向构建目录 ——
    /// 两种情形都要覆盖，否则开发期这条路永远走不到、上线才发现写错了。
    static func locateBundledHubctl() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        let bundle = Bundle.main.bundleURL
        candidates.append(bundle.appendingPathComponent("Contents/Helpers/hubctl"))
        // 开发期：可执行文件和 hubctl 并排躺在 .build/<config>/ 里。
        candidates.append(bundle.appendingPathComponent("hubctl"))
        candidates.append(bundle.deletingLastPathComponent().appendingPathComponent("hubctl"))

        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - 体检

    /// 现在装的是不是对的。设置页拿它显示健康度。
    public func isHealthy() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any]
        else { return false }

        let hubctl = binURL.appendingPathComponent("hubctl").path
        guard FileManager.default.isExecutableFile(atPath: hubctl) else { return false }

        return Self.specs.allSatisfy { spec in
            let entries = hooks[spec.event] as? [[String: Any]] ?? []
            return entries.contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? [])
                    .compactMap { $0["command"] as? String }
                    .contains { $0.hasPrefix(hubctl) && $0.hasSuffix(spec.argument) }
            }
        }
    }
}
