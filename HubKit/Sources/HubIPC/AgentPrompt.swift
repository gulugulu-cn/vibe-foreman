import Foundation

/// AskUserQuestion / ExitPlanMode / EnterPlanMode 的结构化载荷。
///
/// 这几个工具是 Claude 的"交互请求"：选择题、计划审批、模式切换。
/// 它们的 tool_input 里没有 command / file_path，`RiskClassifier` 提不出
/// summary，走风险链路会被当成无风险直接放行 —— 岛上什么都不弹。
/// 所以它们在 HookCoordinator 里按 toolName 分流，走这条独立的解析路径。
public enum AgentPromptPayload: Equatable, Sendable {
    /// 一组问题（1..N 题，含多选题）—— 岛上逐题作答后一并回传。
    case questions([AgentQuestion])
    /// 计划审批（ExitPlanMode）。批准即切出 plan 模式开始执行。
    /// 关联值是计划全文（markdown）。
    case plan(String)
    /// 请求进入计划模式（EnterPlanMode）。
    case enterPlan
    /// 终端里的权限确认框（"Do you want to create xxx?"）。
    ///
    /// **不来自 PreToolUse**：这是 CLI 自己弹的框，hub 只在 Notification hook
    /// 里收到 `permission_prompt`。答案没法从 hook 回传（hook 早已返回），
    /// 要靠往对应终端注入按键（1 = 允许 / Esc = 拒绝）。
    case permission(message: String)
    /// 解析失败 / 超长被裁 / 题目缺选项 —— 岛上只提供「去终端回答」。
    case complex(hint: String)

    /// 需要走交互分流的工具名。
    public static let interactiveTools: Set<String> = [
        "AskUserQuestion", "ExitPlanMode", "EnterPlanMode",
    ]

    /// 从 tool_input 的 JSON 原文解析。非交互工具返回 nil。
    public static func parse(toolName: String, inputJSON: String?) -> AgentPromptPayload? {
        guard interactiveTools.contains(toolName) else { return nil }

        // EnterPlanMode 的 input 就是空对象，不依赖 JSON 内容。
        if toolName == "EnterPlanMode" { return .enterPlan }

        guard let inputJSON,
              let data = inputJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // 旧 hubctl 不带 toolInputJSON、或超长被裁 —— 降级但不能不弹。
            return .complex(hint: toolName == "ExitPlanMode" ? "Claude 提出了一份计划" : "Claude 有问题要问你")
        }

        switch toolName {
        case "ExitPlanMode":
            guard let plan = object["plan"] as? String, !plan.isEmpty else {
                return .complex(hint: "Claude 提出了一份计划")
            }
            return .plan(plan)

        case "AskUserQuestion":
            guard let raw = object["questions"] as? [[String: Any]], !raw.isEmpty
            else { return .complex(hint: "Claude 有问题要问你") }

            var questions: [AgentQuestion] = []
            for item in raw {
                guard let text = item["question"] as? String, !text.isEmpty else {
                    return .complex(hint: "Claude 有问题要问你")
                }
                let options = ((item["options"] as? [[String: Any]]) ?? []).compactMap {
                    option -> AgentQuestion.Option? in
                    guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                    return AgentQuestion.Option(
                        label: label, description: option["description"] as? String
                    )
                }
                guard !options.isEmpty else {
                    // 有一题没有可点的选项，整组都答不完整，只能去终端。
                    return .complex(hint: "Claude 有问题要问你")
                }
                questions.append(
                    AgentQuestion(
                        question: text,
                        header: item["header"] as? String,
                        options: options,
                        multiSelect: (item["multiSelect"] as? Bool) ?? false
                    )
                )
            }
            return .questions(questions)

        default:
            return nil
        }
    }
}

/// 一道选择题（单选或多选）。
public struct AgentQuestion: Equatable, Sendable {
    public struct Option: Equatable, Sendable, Identifiable {
        public let label: String
        public let description: String?
        public var id: String { label }

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public let question: String
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool

    public init(
        question: String, header: String? = nil,
        options: [Option], multiSelect: Bool = false
    ) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// 回传答案时给这道题用的短标签：header 优先，没有就用题干。
    public var answerKey: String { header ?? question }
}

/// 一道题的作答结果，用于拼回传文本。
public struct AgentAnswer: Equatable, Sendable {
    public let key: String
    public let labels: [String]

    public init(key: String, labels: [String]) {
        self.key = key
        self.labels = labels
    }

    public var line: String { "\(key)：\(labels.joined(separator: "、"))" }
}
