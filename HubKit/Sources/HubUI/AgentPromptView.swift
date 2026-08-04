import HubIPC
import SwiftUI

/// 交互作答态视图：Claude 的选择题（AskUserQuestion）、计划审批（ExitPlanMode）、
/// 进入计划模式（EnterPlanMode）。
///
/// 和审批卡不同，这里没有"危险操作"：最坏的结果只是答案不合心意，
/// Claude 会继续对话。所以护栏只保留一条 —— 「批准/同意」有 700ms 时间锁
/// （批准会立刻改变执行方式，值得防误点），其余按钮即点即发。
///
/// 多题表单逐题作答：单选点了自动进下一题，多选勾完点「下一题」，
/// 答完最后一题一并回传。**中途不落任何东西**，去终端或超时都不会发半截答案。
struct AgentPromptContent: View {
    let request: AgentPromptRequest
    let queueCount: Int
    let onSubmitAnswers: ([AgentAnswer]) -> Void
    let onChoose: (AgentQuestion.Option) -> Void
    /// 批准计划：参数是要替用户在终端计划框里按的数字。
    /// 两种已知布局里 1 都是"放开手脚的 Yes"（bypass permissions / auto-accept
    /// edits），2 都是 "Yes, manually approve edits"。
    let onApprovePlanKey: (Int) -> Void
    let onRejectPlan: () -> Void
    let onApproveEnterPlan: () -> Void
    let onRejectEnterPlan: () -> Void
    /// 权限确认框：允许 = 往终端注入按键 1，拒绝 = Esc。
    let onAllowPermission: () -> Void
    let onDenyPermission: () -> Void
    /// 「去终端回答」：不输出决策，终端原生对话框接管，并跳转过去。
    let onGoToTerminal: () -> Void

    /// 同 ApprovalContent 的时间锁：面板刚弹出来的 700ms 内「批准/同意」
    /// 不可用，覆盖"岛主动弹出时指针恰好停在按钮上"的误击窗口。
    @State private var unlocked = false

    /// 多题表单的进度与已选答案（按题序号存选项 label，保持点选顺序）。
    @State private var questionIndex = 0
    @State private var picked: [Int: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(.vertical, 12)
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                unlocked = true
            }
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerSymbol)
                .font(.system(size: 18))
                .foregroundStyle(IslandTheme.waiting)

            VStack(alignment: .leading, spacing: 1) {
                Text(request.projectName)
                    .font(IslandTheme.label(13, .semibold))
                    .foregroundStyle(.white)
                Text(headerSubtitle)
                    .font(IslandTheme.label(11))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if queueCount > 1 {
                Text("1/\(queueCount)")
                    .font(IslandTheme.label(10, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(.white.opacity(0.10), in: .capsule)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var headerSymbol: String {
        switch request.payload {
        case .questions: "questionmark.circle.fill"
        case .plan: "list.clipboard.fill"
        case .enterPlan: "map.fill"
        case .permission: "lock.shield.fill"
        case .complex: "bubble.left.and.exclamationmark.bubble.right.fill"
        }
    }

    private var headerSubtitle: String {
        switch request.payload {
        case .questions(let questions):
            let current = questions[safe: questionIndex]
            let progress = questions.count > 1 ? "第 \(questionIndex + 1)/\(questions.count) 题" : nil
            let header = current?.header
            let tail = current?.multiSelect == true ? "可多选" : nil
            let parts = [progress, header, tail].compactMap(\.self)
            return parts.isEmpty ? "Claude 在等你选择" : parts.joined(separator: " · ")
        case .plan: return "Claude 提出了一份计划"
        case .enterPlan: return "Claude 请求进入计划模式"
        case .permission: return "终端里在等你授权"
        case .complex: return "Claude 在等你的输入"
        }
    }

    // MARK: - content

    @ViewBuilder
    private var content: some View {
        switch request.payload {
        case .questions(let questions):
            if let question = questions[safe: questionIndex] {
                questionBody(question, index: questionIndex)
            }
        case .plan(let plan):
            planBody(plan)
        case .enterPlan:
            enterPlanBody
        case .permission(let message):
            permissionBody(message)
        case .complex(let hint):
            complexBody(hint)
        }
    }

    private func permissionBody(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(IslandTheme.label(13, .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text("「允许」= 替你在终端按 1 · 「拒绝」= 按 Esc")
                .font(IslandTheme.label(11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private func questionBody(_ question: AgentQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .font(IslandTheme.label(12))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // 选项竖排：label 是完整句子，横排放不下。超过可视区内部滚动。
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(question.options) { option in
                        optionRow(option, question: question, index: index)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func optionRow(
        _ option: AgentQuestion.Option, question: AgentQuestion, index: Int
    ) -> some View {
        let selected = picked[index]?.contains(option.label) == true
        return Button {
            tap(option, question: question, index: index)
        } label: {
            HStack(spacing: 8) {
                if question.multiSelect {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? IslandTheme.waiting : .white.opacity(0.4))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(IslandTheme.label(12, .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(IslandTheme.label(10))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .white.opacity(selected ? 0.14 : 0.07),
                in: .rect(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 单选：点了就记下并推进（最后一题直接提交）。多选：只做勾选切换。
    private func tap(_ option: AgentQuestion.Option, question: AgentQuestion, index: Int) {
        if question.multiSelect {
            var current = picked[index] ?? []
            if let at = current.firstIndex(of: option.label) {
                current.remove(at: at)
            } else {
                current.append(option.label)
            }
            picked[index] = current
        } else {
            picked[index] = [option.label]
            advanceOrSubmit()
        }
    }

    private func advanceOrSubmit() {
        guard case .questions(let questions) = request.payload else { return }
        if questionIndex + 1 < questions.count {
            questionIndex += 1
        } else {
            let answers = questions.enumerated().compactMap { index, question -> AgentAnswer? in
                guard let labels = picked[index], !labels.isEmpty else { return nil }
                return AgentAnswer(key: question.answerKey, labels: labels)
            }
            guard answers.count == questions.count else { return }
            // 单题单选保持原来的快捷口径（reason 更短更直接）。
            if answers.count == 1, questions[0].multiSelect == false,
               let label = answers[0].labels.first,
               let option = questions[0].options.first(where: { $0.label == label }) {
                onChoose(option)
            } else {
                onSubmitAnswers(answers)
            }
        }
    }

    private func planBody(_ plan: String) -> some View {
        ScrollView {
            Text(plan)
                .font(IslandTheme.mono(11))
                .foregroundStyle(.white.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .scrollIndicators(.never)
        .frame(height: 150)
        .background(
            Color.black.opacity(0.48),
            in: .rect(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var enterPlanBody: some View {
        VStack(spacing: 8) {
            Text("Claude 想先进入计划模式（plan mode）")
                .font(IslandTheme.label(13, .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Text("同意后它会先做只读调研、给出计划再动手")
                .font(IslandTheme.label(11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private func complexBody(_ hint: String) -> some View {
        VStack(spacing: 8) {
            Text(hint)
                .font(IslandTheme.label(13, .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Text("这个问题岛上答不了，去终端里回答")
                .font(IslandTheme.label(11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: - footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 6) {
            switch request.payload {
            case .questions(let questions):
                questionFooter(questions)
            case .plan:
                planFooter
            case .enterPlan:
                approvalFooter(approveLabel: "同意", onApprove: onApproveEnterPlan, onReject: onRejectEnterPlan)
            case .permission:
                approvalFooter(
                    approveLabel: "允许", rejectLabel: "拒绝",
                    onApprove: onAllowPermission, onReject: onDenyPermission
                )
            case .complex:
                HStack {
                    Spacer(minLength: 0)
                    Button(action: onGoToTerminal) {
                        Text("去终端回答").padding(.horizontal, 12)
                    }
                    .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 32))
                    Spacer(minLength: 0)
                }
            }

            Text("55 秒未作答会自动转到终端处理")
                .font(IslandTheme.label(9))
                .foregroundStyle(.white.opacity(0.38))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func questionFooter(_ questions: [AgentQuestion]) -> some View {
        let question = questions[safe: questionIndex]
        let hasSelection = !(picked[questionIndex] ?? []).isEmpty
        let isLast = questionIndex + 1 >= questions.count

        return HStack(spacing: 10) {
            if questionIndex > 0 {
                Button {
                    questionIndex -= 1
                } label: {
                    Text("上一题").padding(.horizontal, 8)
                }
                .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 32))
            }

            Spacer(minLength: 0)

            Button(action: onGoToTerminal) {
                Text("去终端回答").padding(.horizontal, 8)
            }
            .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 32))

            // 单选题点选项即推进，不需要这颗按钮；多选题要一颗"我勾完了"。
            if question?.multiSelect == true {
                Button {
                    advanceOrSubmit()
                } label: {
                    Text(isLast ? "提交" : "下一题").padding(.horizontal, 12)
                }
                .buttonStyle(IslandButtonStyle(
                    emphasis: .prominent, tint: IslandTheme.waiting, height: 32
                ))
                .disabled(!hasSelection)
                .opacity(hasSelection ? 1 : 0.45)
            }
        }
    }

    /// 计划卡的按钮行。批准分两档 —— 终端计划框里 1/2 的语义差别
    /// （放开权限 vs 逐步确认）不该由 Hub 替用户拍板。
    private var planFooter: some View {
        HStack(spacing: 8) {
            Button(action: onRejectPlan) {
                Text("驳回").padding(.horizontal, 10)
            }
            .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 32))

            Spacer(minLength: 0)

            Button(action: onGoToTerminal) {
                Text("去终端").padding(.horizontal, 8)
            }
            .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 32))

            Button {
                guard unlocked else { return }
                onApprovePlanKey(2)
            } label: {
                Text("批准·逐步确认").padding(.horizontal, 10)
            }
            .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 32))
            .disabled(!unlocked)
            .opacity(unlocked ? 1 : 0.45)

            Button {
                guard unlocked else { return }
                onApprovePlanKey(1)
            } label: {
                Text("批准·放手干").padding(.horizontal, 10)
            }
            .buttonStyle(IslandButtonStyle(
                emphasis: .prominent, tint: IslandTheme.waiting, height: 32
            ))
            .disabled(!unlocked)
            .opacity(unlocked ? 1 : 0.45)
        }
    }

    private func approvalFooter(
        approveLabel: String, rejectLabel: String = "驳回",
        onApprove: @escaping () -> Void, onReject: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button(action: onReject) {
                Text(rejectLabel)
            }
            .buttonStyle(IslandButtonStyle(emphasis: .secondary, width: 110, height: 32))

            Button {
                guard unlocked else { return }
                onApprove()
            } label: {
                Text(approveLabel)
            }
            .buttonStyle(IslandButtonStyle(
                emphasis: .prominent, tint: IslandTheme.waiting, width: 110, height: 32
            ))
            .disabled(!unlocked)
            .opacity(unlocked ? 1 : 0.45)

            Spacer(minLength: 0)

            Button(action: onGoToTerminal) {
                Text("去终端").padding(.horizontal, 8)
            }
            .buttonStyle(IslandButtonStyle(emphasis: .secondary, height: 32))
        }
    }
}

extension Array {
    /// 越界安全下标。多题表单的 index 由 @State 驱动，队列切换的瞬间可能短暂越界。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
