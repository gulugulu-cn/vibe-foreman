import HubCore
import HubProbe
import SwiftUI

/// 岛上应答要回答的那个问题，以及它能怎么答。
public struct AnswerRequest: Equatable, Sendable {
    public let sessionId: String
    public let sessionName: String
    public let question: String
    /// 快捷回答。来自 AI，没有就用通用四件套。
    public let options: [String]
    /// 人能看懂的目标位置（"iTerm · storefront-a-47"）。发送预览要显示它。
    public let target: String?

    public init(
        sessionId: String, sessionName: String, question: String,
        options: [String], target: String?
    ) {
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.question = question
        self.options = options
        self.target = target
    }

    /// AI 没给选项时的兜底。刻意包含"稍后"——
    /// 只给"是/否"会逼用户在没准备好的时候二选一，而他真正想做的往往是
    /// "先不回答，但别再问我了"。
    public static let genericOptions = ["继续", "是", "否", "稍后"]
}

/// 应答态。**点了按钮不直接发，先出预览让用户确认一次。**
///
/// 多这一步的理由：刘海很小，而用户很可能在剔需要背景知识的情况下随手点一下 ——
/// 而那一下可能是往生产环境推代码（用户实拍的例子里，那个"是"意味着
/// 真往 Shopify live 推）。预览把"我要发什么、发到哪"摊开，
/// 把一次随手点变成一次明确决定。
struct AnswerContent: View {

    let request: AnswerRequest
    /// 确认发送。参数是最终要发出去的那一行。
    let onSend: (String) -> Void
    let onJump: () -> Void
    let onDismiss: () -> Void
    /// 发送结果的回显。发完不告诉用户成没成，他只能自己切过去看。
    let feedback: String?
    /// 清掉上一次的回显。
    ///
    /// 失败之后用户点「取消」回到选项界面，那条"发送失败"如果还挂着，
    /// 读起来就像**这一次**也失败了。任何新动作都要先把它抹掉。
    let onClearFeedback: () -> Void

    /// 已经选好、正在等确认的那一条。`nil` 表示还在选。
    @State private var pending: String?

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.answerGap) {
            header
            if let pending {
                preview(for: pending)
                confirmButtons(for: pending)
            } else {
                question
                optionButtons
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, IslandMetrics.answerVerticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("❓")
                .font(.system(size: 11))
            Text(request.sessionName)
                .font(IslandTheme.label(12, .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let feedback {
                Text(feedback)
                    .font(IslandTheme.label(10, .medium))
                    .foregroundStyle(IslandTheme.waiting)
                    .lineLimit(1)
            }
        }
        .frame(height: IslandMetrics.answerHeaderHeight)
    }

    private var question: some View {
        Text(request.question)
            .font(IslandTheme.label(12, .regular))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: .infinity,
                minHeight: IslandMetrics.answerQuestionHeight,
                alignment: .topLeading
            )
    }

    private var optionButtons: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    onClearFeedback()
                    pending = option
                } label: {
                    // 样式本身只给 frame 不给内边距，横向留白得自己加，
                    // 否则文字会贴到圆角边上。
                    Text(option).padding(.horizontal, 10)
                }
                .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 26))
            }
            Spacer(minLength: 0)
            Button {
                onJump()
            } label: {
                Text("去终端").padding(.horizontal, 8)
            }
            .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 26))
        }
        .frame(height: IslandMetrics.answerButtonsHeight)
    }

    private var options: [String] {
        request.options.isEmpty ? AnswerRequest.genericOptions : request.options
    }

    /// 发送预览。**目标位置必须显示** —— 同一个项目开三个会话时，
    /// "发到 storefront-a" 和 "发到 storefront-a 的哪个窗口" 是两回事。
    private func preview(for text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("将发送到 \(request.target ?? "该会话的终端")：")
                .font(IslandTheme.label(10, .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(text)
                .font(IslandTheme.label(13, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
        }
        .frame(
            maxWidth: .infinity,
            minHeight: IslandMetrics.answerPreviewHeight,
            alignment: .topLeading
        )
    }

    private func confirmButtons(for text: String) -> some View {
        HStack(spacing: 6) {
            Button {
                onSend(text)
            } label: {
                Text("确认发送").padding(.horizontal, 12)
            }
            .buttonStyle(IslandButtonStyle(
                emphasis: .prominent, tint: IslandTheme.waiting, height: 26
            ))

            Button {
                onClearFeedback()
                pending = nil
            } label: {
                Text("取消").padding(.horizontal, 10)
            }
            .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 26))

            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Text("关掉").padding(.horizontal, 8)
            }
            .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 26))
        }
        .frame(height: IslandMetrics.answerButtonsHeight)
    }
}
