import HubProjects
import SwiftUI

/// 一个「改完才提交」的文本框。
///
/// 不用 `Binding` 直接写回 store：那样每敲一个字符都要走一遍
/// 加密 → 原子写 → 重新物化 `.env`。功能上没错，但会把密钥文件反复重写，
/// 而每次重写都是一次权限回归的窗口（`.atomic` 换 inode）。
///
/// 所以这里在本地攒着，**回车或者失焦**才提交一次，而且值没变就不提交。
struct EditableText: View {
    let placeholder: String
    let value: String
    var monospaced: Bool = false
    var onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
            .focused($focused)
            .onAppear { draft = value }
            // store 那边被别的路径改了（比如撤销、重新加载），要跟上。
            .onChange(of: value) { _, new in if !focused { draft = new } }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard draft != value else { return }
        onCommit(draft)
    }
}

/// 带遮蔽开关的值输入框。
///
/// 默认遮蔽。这不是装饰 —— 这台机器上截图工具是可用的，
/// 一个默认全展开的密钥列表等于把所有值挂在屏幕上。
struct SecretValueField: View {
    let value: String
    var placeholder: String = "值"
    @Binding var revealed: Bool
    var onCommit: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if revealed {
                EditableText(placeholder: placeholder, value: value, monospaced: true, onCommit: onCommit)
            } else {
                // 遮蔽态用 SecureField，而不是把明文塞进普通 TextField 再画个遮罩 ——
                // 后者在辅助功能、拖拽、截屏里都是明文。
                SecureFieldProxy(value: value, placeholder: placeholder, onCommit: onCommit)
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed ? "遮起来" : "显示")
        }
    }
}

/// `SecureField` 版本的「改完才提交」。
struct SecureFieldProxy: View {
    let value: String
    let placeholder: String
    var onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !focused { draft = new } }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard draft != value else { return }
        onCommit(draft)
    }
}

/// 库打不开时顶部那条横幅。
///
/// **必须显眼，而且必须说清楚是哪一种。** 「钥匙不对」和「文件坏了」
/// 用户要做的事完全不同：前者去找恢复码，后者是文件真没了。
/// 含混的一句「加载失败」只会让用户自己去删文件重来 —— 而那正是最坏的处置。
struct VaultStateBanner: View {
    let state: VaultLoadState
    var onRecover: (() -> Void)?

    var body: some View {
        switch state {
        case .loaded, .empty:
            EmptyView()
        case .locked(let reason):
            banner(
                symbol: "lock.trianglebadge.exclamationmark",
                color: IslandTheme.waiting,
                title: "打不开，已停止一切写入",
                detail: reason + "\n数据还在，没有被改动。"
            )
        case .broken(let path):
            banner(
                symbol: "exclamationmark.triangle.fill",
                color: IslandTheme.danger,
                title: "文件损坏，已改名保住",
                detail: "原文件在 \(path)。这里可以重新开始。"
            )
        }
    }

    @ViewBuilder
    private func banner(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let onRecover {
                Button("用恢复码恢复…", action: onRecover).font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 20)
    }
}
