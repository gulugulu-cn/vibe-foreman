import Foundation

/// 主窗口「新建项目」表单背后的命令模型。
///
/// 真正干活的是 `scripts/new-project.sh`（和 /new-project skill、命令行共用
/// 同一份逻辑）—— app 只负责收集参数、拼命令、展示输出。建仓逻辑只维护一份。
public struct NewProjectCommand: Equatable, Sendable {

    public enum Remote: String, CaseIterable, Identifiable, Sendable {
        case privateRepo
        case publicRepo
        case localOnly

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .privateRepo: "GitHub 私有仓"
            case .publicRepo: "GitHub 公开仓"
            case .localOnly: "只建本地仓"
            }
        }
    }

    public var name: String = ""
    public var parentDir: String = "~/Documents/code"
    public var remote: Remote = .privateRepo
    /// 防污染 deny（禁止项目会话写宿主机 ~/.claude/ 的全局面）。
    public var applyDenyGuard: Bool = true
    public var descriptionText: String = ""

    public init() {}

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提交前校验。nil = 可以提交。
    public var validationError: String? {
        let value = trimmedName
        if value.isEmpty { return "项目名不能为空" }
        if value.contains(where: { $0 == "/" || $0 == "\\" || $0.isWhitespace }) {
            return "项目名不能含空格或斜杠"
        }
        if value.hasPrefix("-") { return "项目名不能以 - 开头" }
        if parentDir.trimmingCharacters(in: .whitespaces).isEmpty { return "父目录不能为空" }
        return nil
    }

    /// 目标路径（展示用）。
    public var targetPath: String {
        let parent = NSString(string: parentDir).expandingTildeInPath
        return "\(parent)/\(trimmedName)"
    }

    /// 拼给 `/bin/bash <script> ...` 的参数。
    public func arguments(scriptPath: String) -> [String] {
        var args = [scriptPath, trimmedName, "--dir", parentDir]
        switch remote {
        case .privateRepo: args.append("--private")
        case .publicRepo: args.append("--public")
        case .localOnly: args.append("--no-remote")
        }
        if !applyDenyGuard { args.append("--no-deny") }
        let desc = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { args += ["--desc", desc] }
        return args
    }

    /// 定位 new-project.sh：优先 CLAUDE_HUB_DIR，其次 projects.yaml 所在目录
    /// （yaml 就住在 hub 仓库根下），最后默认克隆位置。
    public static func scriptURL(near yamlURL: URL?) -> URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_HUB_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath)
                .appendingPathComponent("scripts/new-project.sh")
        }
        if let yamlURL {
            let candidate = yamlURL.deletingLastPathComponent()
                .appendingPathComponent("scripts/new-project.sh")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/code/vibe-foreman/scripts/new-project.sh")
    }

    /// GUI app 从 launchd 继承的 PATH 只有系统四件套，gh（/usr/local/bin 或
    /// /opt/homebrew/bin）会找不到 —— 跑脚本必须显式补全。
    public static let guiPATH =
        "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}
