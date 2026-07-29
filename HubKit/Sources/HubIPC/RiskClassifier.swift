import Foundation

/// 操作的风险等级。
public enum RiskLevel: String, Codable, Sendable, Comparable {
    /// 日常操作。直接放行，不打扰。
    case normal
    /// 危险但可恢复。默认只记录不拦截。
    case dangerous
    /// 不可逆。拦截并要求按住确认。
    case irreversible

    private var rank: Int {
        switch self {
        case .normal: return 0
        case .dangerous: return 1
        case .irreversible: return 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }
}

/// 判断一次工具调用有多危险。
///
/// 设计取向：**默认只拦 `irreversible`**。
///
/// 用户全局是 `permissions.defaultMode = auto` 且常用 `--dangerously-skip-permissions`，
/// 图的就是不被打断。如果把 `dangerous` 一档也拦上，按日常用量每天会弹 3–8 次，
/// 那等于把用户特意关掉的东西又装回去，结果必然是他把整个功能关掉。
///
/// 所以 `dangerous` 先只进审批日志，攒一周数据之后用户自己决定要不要开启拦截。
public struct RiskClassifier: Sendable {

    /// 达到或超过这个等级才拦截。
    public let interceptThreshold: RiskLevel

    public init(interceptThreshold: RiskLevel = .irreversible) {
        self.interceptThreshold = interceptThreshold
    }

    public func shouldIntercept(_ level: RiskLevel) -> Bool {
        level >= interceptThreshold && level != .normal
    }

    /// 对一次工具调用定级。
    public func classify(toolName: String?, summary: String?) -> RiskLevel {
        guard let toolName else { return .normal }

        // 只读工具永远不拦。把它们显式列出来，避免正则在文件内容里误命中 ——
        // 比如 Read 一个讲 `rm -rf` 的 README 不该触发审批。
        let readOnlyTools: Set<String> = [
            "Read", "Grep", "Glob", "WebFetch", "WebSearch", "TodoWrite", "Task",
        ]
        if readOnlyTools.contains(toolName) { return .normal }

        guard let summary, !summary.isEmpty else { return .normal }
        let text = summary.lowercased()

        if Self.irreversiblePatterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
            return .irreversible
        }
        if Self.dangerousPatterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
            return .dangerous
        }
        return .normal
    }

    // MARK: - 规则集

    /// 不可逆：数据没了就是没了，或者影响到线上。
    ///
    /// 每条都写成正则并加了边界，尽量避免误伤：
    /// 比如 `rm -rf /` 要求斜杠后面不能再跟路径字符，这样 `rm -rf /tmp/x` 不会命中。
    static let irreversiblePatterns: [String] = [
        // rm -rf 到根、到家目录、或到某个盘符根
        #"\brm\s+(-[a-z]*\s+)*-?[a-z]*r[a-z]*f?[a-z]*\s+/\s*$"#,
        #"\brm\s+.*-[a-z]*r[a-z]*\s+(~|\$home)\s*/?\s*$"#,
        #"\brm\s+.*\s/\*"#,
        // 强推保护分支
        #"git\s+push\s+.*(--force|-f)\b.*\b(main|master|prod|production|release)\b"#,
        #"git\s+push\s+.*\b(main|master|prod|production|release)\b.*(--force|-f)\b"#,
        // 删库
        #"drop\s+database\b"#,
        #"drop\s+schema\b"#,
        // 生产部署 / 集群删除
        #"kubectl\s+delete\b"#,
        #"\bdeploy\S*\s+.*\bprod(uction)?\b"#,
        #"\bterraform\s+destroy\b"#,
        // 磁盘级操作
        #"\bmkfs\b"#,
        #"\bdd\s+.*of=/dev/"#,
        #"diskutil\s+(erase|reformat)"#,
    ]

    /// 危险但可恢复。
    static let dangerousPatterns: [String] = [
        #"\brm\s+(-[a-z]*\s+)*-[a-z]*r[a-z]*f"#,      // 任意 rm -rf
        #"git\s+push\s+.*(--force\b|--force-with-lease\b|\s-f\b)"#,
        #"git\s+reset\s+--hard\b"#,
        #"git\s+clean\s+.*-[a-z]*f"#,
        #"git\s+branch\s+-D\b"#,
        #"\bchmod\s+(-[a-z]+\s+)*777\b"#,
        #"\bdrop\s+table\b"#,
        #"\btruncate\s+table\b"#,
        #"\bdelete\s+from\b(?!.*\bwhere\b)"#,          // 无 WHERE 的 DELETE
        #"curl\s+[^|]*\|\s*(sudo\s+)?(ba|z|k)?sh"#,    // curl | sh
        #"wget\s+[^|]*\|\s*(sudo\s+)?(ba|z|k)?sh"#,
        #"\bnpm\s+publish\b"#,
        #"\bdocker\s+(system\s+)?prune\b"#,
        #"\bsudo\b"#,
        #"\.ssh/(id_|authorized_keys)"#,
        #"\.env\b"#,
        #"\bkill(all)?\s+-9\b"#,
    ]

    /// 从工具参数里挑出最能代表"这次要干什么"的那个值。
    ///
    /// hubctl 侧调用，把提取好的字符串放进 `HookEvent.toolSummary`，
    /// 这样服务端不用背着完整的 tool_input schema。
    public static func summarize(toolName: String, input: [String: Any]) -> String? {
        // 顺序有意义：command 最能说明问题，其次是路径。
        for key in ["command", "file_path", "path", "url", "pattern", "notebook_path"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value
            }
        }
        return input["description"] as? String
    }
}
