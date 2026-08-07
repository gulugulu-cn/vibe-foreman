import Foundation

/// 处理模型回复的公共部分。
///
/// 抽出来是因为「剥 ``` 围栏」这件事**每一个调模型的地方都要做**：
/// 实测即使提示词明说"只输出 JSON 对象"，模型仍然会包一层 ```json … ```。
/// 不剥的话解析必然失败，那一整层 AI 能力等于完全没生效 —— 而且是静默失败。
///
/// 各写一份的话，某天有人在一处修了新的边界情况（比如围栏前面还有一句话），
/// 另一处不会跟着修。
public enum ModelOutput {

    /// 剥掉 markdown 代码围栏，返回里面的内容。没有围栏就原样返回（已 trim）。
    public static func stripCodeFence(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeFirst()   // ```json 或 ```
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// 从模型回复里挖出一个 JSON 对象。
    ///
    /// 比 `stripCodeFence` 更宽容：模型经常在 JSON 前后各写一段散文
    /// （"好的，我核对了一遍：{…} 需要我继续吗？"）。这时围栏剥不出东西，
    /// 只能退回去找第一个 `{` 和最后一个 `}`。
    ///
    /// **这不是过度设计。** 自查回答那条链路上，模型是在一段长对话的末尾
    /// 被要求输出 JSON 的，它加几句客套话是常态而不是异常。
    public static func extractJSONObject(_ raw: String) -> [String: Any]? {
        let stripped = stripCodeFence(raw)

        if let object = parseObject(stripped) { return object }

        guard let start = stripped.firstIndex(of: "{"),
              let end = stripped.lastIndex(of: "}"),
              start < end
        else { return nil }
        return parseObject(String(stripped[start...end]))
    }

    private static func parseObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
