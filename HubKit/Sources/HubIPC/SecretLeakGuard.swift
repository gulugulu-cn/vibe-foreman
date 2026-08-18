import Foundation

/// 拦住「把密钥写出去」的那一类工具调用。
///
/// ## 它防的是什么
///
/// AI 时代最贵的一类事故不是它删了文件，是它**把密钥搬到了不该在的地方**：
/// 顺手 `git add .` 把 `.env` 一起提了、把真实的 token 内联进配置文件当"示例"、
/// 在 commit message 或 README 里贴一段"完整的调用示例"。
/// 这些操作单看每一步都很正常，所以任何基于"这条命令危不危险"的判断都拦不住 ——
/// 唯一可靠的信号是**这次调用的内容里有没有出现真实的密钥值**。
///
/// ## 为什么跑在 hubctl 里而不是 app 里
///
/// 仓库其它拦截都是 app 侧决策，app 没开就放行（「一个监控工具不该让你的命令跑不起来」）。
/// 这一条反过来：**密钥泄漏是不可逆的**，一次就够。
/// 所以判断放在 hubctl 本地，不依赖 app 在不在跑。
///
/// 代价是它看不到岛上的界面，也拿不到加密库里的值 —— 它只能读**已经物化到磁盘**的
/// 那几个 `.env`。这是刻意的：那些文件本来就是明文、就是给 AI 用的，
/// hubctl 读它们不增加任何暴露面。关掉「物化到磁盘」之后值级拦截跟着失效，
/// 但那时候磁盘上本来也没有值可漏。
///
/// ## fail-open
///
/// 任何异常一律放行。这条是全案最高原则：一个卡死的 hook 比一次漏审危害大得多。
public enum SecretLeakGuard {

    public struct Finding: Sendable, Equatable {
        /// 给 Claude 看的原因。要说清楚**正确的做法是什么**，
        /// 否则它只会换个写法再试一次。
        public let reason: String
        /// 给审批日志用的短标签。
        public let label: String
    }

    /// 值太短就不参与匹配 —— `1`、`true`、`test` 这种会命中一切。
    /// 8 个字符是经验值：比它短的东西当密钥用本来也不安全。
    static let minimumValueLength = 8

    /// 一次扫描最多看多少个待提交文件。防的是有人 `git add .` 一个几万文件的仓库。
    static let maxScannedFiles = 200
    /// 单个文件超过这个大小就不看内容了。密钥不会藏在 1MB 的文件里，
    /// 而全读进来会让一次 commit 卡住。
    static let maxScannedFileBytes = 256 * 1024

    // MARK: - 入口

    /// - Returns: nil = 没发现问题，放行。
    public static func inspect(
        toolName: String,
        input: [String: Any],
        cwd: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Finding? {
        guard isEnabled(home: home) else { return nil }

        let secrets = materializedSecrets(home: home)

        // 1) 这次调用的参数里直接带了密钥值。
        if let hit = firstSecret(in: flattenStrings(input), secrets: secrets) {
            return Finding(
                reason: """
                这次调用里出现了 \(hit.key) 的真实值，已被 Vibe Foreman 拦下。
                别把值写进文件或命令行 —— 用 `set -a; source '\(hit.file)'; set +a` \
                之后引用 $\(hit.key)，值就只存在于那条命令的环境里。
                """,
                label: "带着 \(hit.key) 的真实值"
            )
        }

        // 2) git add / git commit 会不会把密钥带进仓库。
        if toolName == "Bash", let command = input["command"] as? String {
            return gitLeak(command: command, cwd: cwd, secrets: secrets)
        }
        return nil
    }

    // MARK: - 开关

    /// 默认开。文件不存在 = 开着 —— 一个保护性的默认值不该依赖某个文件存在。
    static func isEnabled(home: URL) -> Bool {
        let url = home.appendingPathComponent(".vibe-foreman/guard.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = json["enabled"] as? Bool
        else { return true }
        return enabled
    }

    // MARK: - 密钥值

    struct Secret: Equatable {
        let key: String
        let value: String
        /// 值来自哪个物化文件。拒绝理由里要告诉 Claude 该 source 哪一个。
        let file: String
    }

    /// 读所有物化出来的 `.env`。
    ///
    /// 读**全部**而不是只读当前项目那一份：项目 A 的会话手上不该有项目 B 的密钥，
    /// 但万一有（用户自己粘过去的、上一轮遗留在上下文里的），照样要拦。
    static func materializedSecrets(home: URL) -> [Secret] {
        let dir = home.appendingPathComponent(".vibe-foreman/env/by-project")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }

        var out: [Secret] = []
        for name in names where name.hasSuffix(".env") {
            let path = dir.appendingPathComponent(name).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            out += parse(text, file: path)
        }
        return out
    }

    /// 解析 `EnvRenderer` 写出来的那个子集：`export KEY='值'`，
    /// 单引号内直到下一个单引号（可以跨行）。
    ///
    /// 只认自己写出来的格式，不做通用 dotenv 解析 —— 解析器判宽了会把注释里的
    /// 片段当成值，然后到处误伤。
    static func parse(_ text: String, file: String) -> [Secret] {
        var out: [Secret] = []
        var rest = Substring(text)

        while let exportRange = rest.range(of: "\nexport ") ?? rest.range(of: "export ", options: .anchored) {
            rest = rest[exportRange.upperBound...]
            guard let eq = rest.firstIndex(of: "=") else { break }
            let key = String(rest[rest.startIndex..<eq])
            guard !key.contains("\n"), !key.isEmpty else { continue }

            var tail = rest[rest.index(after: eq)...]
            guard tail.first == "'" else { continue }
            tail = tail.dropFirst()
            guard let end = tail.firstIndex(of: "'") else { break }

            let value = String(tail[tail.startIndex..<end])
            if value.count >= minimumValueLength {
                out.append(Secret(key: key, value: value, file: file))
            }
            rest = tail[end...]
        }
        return out
    }

    // MARK: - 匹配

    /// 把 tool_input 里所有字符串摊平。嵌套的（MultiEdit 的 edits 数组）也要看，
    /// 只看顶层的话，把密钥放进数组里就绕过去了。
    static func flattenStrings(_ any: Any) -> [String] {
        switch any {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap(flattenStrings)
        case let d as [String: Any]: return d.values.flatMap(flattenStrings)
        default: return []
        }
    }

    static func firstSecret(in haystacks: [String], secrets: [Secret]) -> Secret? {
        for secret in secrets {
            for text in haystacks where text.contains(secret.value) {
                return secret
            }
        }
        return nil
    }

    // MARK: - git

    /// 这些名字的文件本来就不该进仓库。
    ///
    /// 后缀是 `.example` / `.template` / `.sample` 的放过 —— 那是**给人看的骨架**，
    /// 提交它正是正确做法，拦下来只会让人把整个功能关掉。
    static func looksLikeSecretFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        for suffix in [".example", ".template", ".sample", ".dist"] where name.hasSuffix(suffix) {
            return false
        }
        if name == ".env" || name.hasPrefix(".env.") { return true }
        if name.hasSuffix(".pem") || name.hasSuffix(".p12") || name.hasSuffix(".pfx") { return true }
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") { return true }
        if name == "credentials.json" || name.hasPrefix("service-account") { return true }
        if name == ".netrc" || name == ".npmrc" || name == ".pypirc" { return true }
        return false
    }

    static func gitLeak(command: String, cwd: String, secrets: [Secret]) -> Finding? {
        guard command.range(of: #"\bgit\b[^|;&]*\b(add|commit)\b"#, options: .regularExpression) != nil
        else { return nil }

        let files = filesEnteringTheRepository(command: command, cwd: cwd)
        guard !files.isEmpty else { return nil }

        for path in files.prefix(maxScannedFiles) {
            if looksLikeSecretFile(path) {
                return Finding(
                    reason: """
                    `\(path)` 要进仓库了，已被 Vibe Foreman 拦下 —— 这类文件不该被提交。
                    先把它加进 .gitignore（已经提交过的话还要 `git rm --cached`），\
                    密钥交给 Vibe Foreman 的「共用密钥」管。
                    确实是模板文件的话，改名成 `.example` 结尾再提交。
                    """,
                    label: "要提交 \((path as NSString).lastPathComponent)"
                )
            }
            let full = (path as NSString).isAbsolutePath
                ? path : (cwd as NSString).appendingPathComponent(path)
            guard let size = try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int,
                  size <= maxScannedFileBytes,
                  let text = try? String(contentsOfFile: full, encoding: .utf8)
            else { continue }

            if let hit = firstSecret(in: [text], secrets: secrets) {
                return Finding(
                    reason: """
                    `\(path)` 里有 \(hit.key) 的真实值，要跟着这次提交进仓库了，\
                    已被 Vibe Foreman 拦下。
                    把那一行换成从环境变量读，值留在 \(hit.file) 里。
                    """,
                    label: "\((path as NSString).lastPathComponent) 里有 \(hit.key)"
                )
            }
        }
        return nil
    }

    /// 这次 `git add` / `git commit` 会让哪些文件进仓库。
    ///
    /// 一律 fail-open：跑不了 git、不在仓库里、输出看不懂，都返回空 = 放行。
    static func filesEnteringTheRepository(command: String, cwd: String) -> [String] {
        var files: [String] = []

        // git commit：看已经暂存的。`-a` 还会带上所有已跟踪的改动。
        if command.range(of: #"\bgit\b[^|;&]*\bcommit\b"#, options: .regularExpression) != nil {
            files += git(["diff", "--cached", "--name-only"], cwd: cwd)
            if command.range(of: #"commit[^|;&]*\s-[a-zA-Z]*a"#, options: .regularExpression) != nil {
                files += git(["diff", "--name-only"], cwd: cwd)
            }
        }

        // git add：`.` / `-A` / `-u` 要问 git，显式路径直接用。
        if command.range(of: #"\bgit\b[^|;&]*\badd\b"#, options: .regularExpression) != nil {
            if command.range(of: #"\badd\b[^|;&]*(\s\.(\s|$)|\s-A\b|\s--all\b|\s-u\b)"#,
                             options: .regularExpression) != nil {
                files += git(["status", "--porcelain", "--untracked-files=all"], cwd: cwd)
                    .compactMap { line in
                        // `XY path`，重命名是 `R  old -> new`，取新的那个。
                        guard line.count > 3 else { return nil }
                        let path = String(line.dropFirst(3))
                        return path.components(separatedBy: " -> ").last
                    }
            } else {
                files += explicitAddPaths(command)
            }
        }
        return files
    }

    /// 从 `git add a b c` 里挑出路径。只做最朴素的切词 ——
    /// 判错了就是少拦一次（fail-open），不会误伤。
    static func explicitAddPaths(_ command: String) -> [String] {
        guard let addRange = command.range(of: #"\badd\b"#, options: .regularExpression)
        else { return [] }
        // 只看到第一个管道/分号为止，后面是另一条命令了。
        let tail = command[addRange.upperBound...]
        let segment = tail.prefix { $0 != "|" && $0 != ";" && $0 != "&" }
        return segment
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-") }
    }

    static func git(_ arguments: [String], cwd: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
