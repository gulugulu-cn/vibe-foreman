import HubCore
import HubIPC
import SwiftUI

/// 事件闯入的内容。
public struct IntrusionEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case finished       // Claude 完成一轮
        case needsInput     // 等待输入或授权
    }

    public let kind: Kind
    public let sessionId: String
    public let title: String
    public let detail: String

    public init(kind: Kind, sessionId: String, title: String, detail: String) {
        self.kind = kind
        self.sessionId = sessionId
        self.title = title
        self.detail = detail
    }

    var accent: Color {
        switch kind {
        case .finished: return IslandTheme.busy
        case .needsInput: return IslandTheme.waiting
        }
    }

    var symbol: String {
        switch kind {
        case .finished: return "checkmark.circle.fill"
        case .needsInput: return "exclamationmark.circle.fill"
        }
    }
}

/// 闯入态视图。
struct IntrusionContent: View {
    let event: IntrusionEvent
    let session: AgentSession?

    var body: some View {
        HStack(spacing: 12) {
            if let session {
                SpriteScreen(cornerRadius: 7) {
                    PixelSprite(session: session, pixelSize: 2, gridSize: 16)
                }
            } else {
                Image(systemName: event.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(event.accent)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(IslandTheme.label(13, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(event.detail)
                    .font(IslandTheme.label(11))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: event.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(event.accent)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 审批态视图。
///
/// 这是整个 app 里**唯一一个做错了会真的删掉代码**的地方，所以防误点护栏是冗余的：
/// 六重保护叠加，任何单点失效都不至于误放行。
struct ApprovalContent: View {
    let request: ApprovalRequest
    let queueCount: Int
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onSkip: () -> Void

    /// ① 时间锁：面板出现后 700ms 内「允许」不可用。
    ///
    /// 这同时也覆盖掉了「闯入态膨胀时指针恰好停在展开区域」的误击窗口 ——
    /// 岛是会主动弹出来的，用户的手可能正好在那儿。
    @State private var unlocked = false
    /// ② 长按进度（仅 L3）。
    @State private var holdProgress: Double = 0
    @State private var holdTask: Task<Void, Never>?
    /// ③ 指针冷却：进入面板后 120ms 内的点击全丢弃。
    @State private var pointerSettledAt: Date?

    private var allowEnabled: Bool {
        guard unlocked else { return false }
        guard let settled = pointerSettledAt else { return true }
        return Date().timeIntervalSince(settled) > 0.12
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            commandBlock
            Spacer(minLength: 0)
            buttons
        }
        .padding(.vertical, 12)
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                unlocked = true
            }
        }
        .onContinuousHover { phase in
            if case .active = phase, pointerSettledAt == nil {
                pointerSettledAt = Date()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: request.risk == .irreversible
                ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(riskColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(request.projectName)
                    .font(IslandTheme.label(13, .semibold))
                    .foregroundStyle(.white)
                Text(request.toolName)
                    .font(IslandTheme.label(11))
                    .foregroundStyle(.white.opacity(0.62))
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
                    .onTapGesture(perform: onSkip)
            }

            Text(riskLabel)
                .font(IslandTheme.label(10, .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(riskColor, in: .capsule)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var commandBlock: some View {
        ScrollView {
            Text(request.command)
                .font(IslandTheme.mono(12))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .scrollIndicators(.never)
        .frame(height: 84)
        .background(
            // 这块是我们自己压暗的深色底，所以下面放什么材质都可控。
            Color.black.opacity(0.48),
            in: .rect(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, 16)
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Button(action: onDeny) {
                    Text("拒绝")
                }
                // 不用系统的 .glass：岛的 panel 基本不是 key window，
                // AppKit 会把非活跃窗口里的系统按钮整体去饱和，两个按钮都变灰 ——
                // 在唯一需要立刻决策的地方显示成"点不了"是不可接受的。
                .buttonStyle(IslandButtonStyle(
                    emphasis: .secondary, width: 120, height: 34
                ))
                // ⑤ 默认动作是拒绝。⏎ 和 ⎋ 都拒绝，「允许」必须 ⌘⏎。
                // **永远不要让 Return 触发允许。**
                .keyboardShortcut(.defaultAction)

                // ① 空间隔离：24pt 间距，故意大于 GlassEffectContainer 的 22pt 融合阈值，
                // 让两个按钮保持独立、不粘连成一块玻璃（粘连会助长误点）。
                Spacer().frame(width: 24)

                allowButton
            }

            // 键盘提示。
            //
            // 这个 app 是 .accessory + nonactivatingPanel，面板未必拿得到 key ——
            // 拿不到时 SwiftUI 的 .keyboardShortcut 是死的，由 IslandController 的
            // 局部按键监听接管。两条路的键位语义完全一致，所以提示始终成立。
            Text(request.requiresHoldToConfirm
                ? "⏎ / ⎋ 拒绝 · 允许必须按住"
                : "⏎ / ⎋ 拒绝 · ⌘⏎ 允许")
                .font(IslandTheme.label(9))
                .foregroundStyle(.white.opacity(0.38))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var allowButton: some View {
        let label = request.requiresHoldToConfirm
            ? (holdProgress > 0 ? "按住…" : "按住确认")
            : "允许"

        Button(action: {
            // ④ L3 必须长按，普通点击不生效。
            guard !request.requiresHoldToConfirm else { return }
            guard allowEnabled else { return }
            onAllow()
        }) {
            ZStack {
                if request.requiresHoldToConfirm {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(.black.opacity(0.28))
                            .frame(width: proxy.size.width * holdProgress)
                    }
                }
                Text(label)
            }
        }
        .buttonStyle(IslandButtonStyle(
            emphasis: .prominent, tint: riskColor, width: 120, height: 34
        ))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!allowEnabled)
        .opacity(allowEnabled ? 1 : 0.45)
        .overlay {
            // 时间锁的可视化：一圈进度环，让用户知道为什么点不了。
            if !unlocked {
                Circle()
                    .stroke(.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 16, height: 16)
            }
        }
        .simultaneousGesture(holdGesture)
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard request.requiresHoldToConfirm, allowEnabled, holdTask == nil else { return }
                holdTask = Task {
                    let steps = 30
                    for step in 1...steps {
                        try? await Task.sleep(for: .milliseconds(30))
                        if Task.isCancelled { return }
                        holdProgress = Double(step) / Double(steps)
                    }
                    if !Task.isCancelled { onAllow() }
                }
            }
            .onEnded { _ in
                // 松手过早：取消并把进度弹回去。
                holdTask?.cancel()
                holdTask = nil
                withAnimation(.spring(response: 0.25)) { holdProgress = 0 }
            }
    }

    private var riskColor: Color {
        request.risk == .irreversible ? IslandTheme.danger : IslandTheme.waiting
    }

    private var riskLabel: String {
        request.risk == .irreversible ? "不可逆" : "危险操作"
    }
}
