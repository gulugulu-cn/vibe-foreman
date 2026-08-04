import AppKit
import HubProbe
import HubProjects
import SwiftUI

/// 主窗口的「新建项目」表单。
///
/// 真正干活的是 `scripts/new-project.sh`（命令行、/new-project skill、这里
/// 三个入口共用同一份逻辑），app 只收集参数、跑脚本、展示输出 ——
/// 建仓流程只维护一份，改脚本三处同时生效。
struct NewProjectSheet: View {
    let projects: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var command = NewProjectCommand()
    @State private var phase: Phase = .editing
    @State private var output = ""

    private enum Phase: Equatable {
        case editing
        case running
        case finished(success: Bool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建项目")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            form

            if let error = command.validationError, phase == .editing,
               !command.name.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if phase == .editing {
                Text("将创建：\(command.targetPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if phase != .editing {
                outputView
            }

            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("项目名")
                TextField("如 feed-sync", text: $command.name)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("父目录")
                HStack(spacing: 6) {
                    TextField("~/Documents/code", text: $command.parentDir)
                        .textFieldStyle(.roundedBorder)
                    Button("选…") { pickParentDir() }
                }
            }
            GridRow {
                Text("描述")
                TextField("可选，进 README 和项目列表", text: $command.descriptionText)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("远程")
                Picker("", selection: $command.remote) {
                    ForEach(NewProjectCommand.Remote.allCases) { remote in
                        Text(remote.label).tag(remote)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            GridRow {
                Text("")
                Toggle(isOn: $command.applyDenyGuard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("防污染 deny（推荐）")
                            .font(.system(size: 12))
                        Text("禁止项目会话写宿主机 ~/.claude/ 全局面；记忆落项目内。plans 刻意放行。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(phase == .running)
    }

    private var outputView: some View {
        ScrollView {
            Text(output.isEmpty ? "执行中…" : output)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxHeight: 140)
        .background(Color.black.opacity(0.05), in: .rect(cornerRadius: 6))
    }

    private var buttons: some View {
        HStack {
            if case .finished(let success) = phase, success {
                Label("已创建并加入项目列表", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
            Spacer()
            if case .finished = phase {
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("取消") { dismiss() }
                    .disabled(phase == .running)
                Button(phase == .running ? "创建中…" : "创建") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.validationError != nil || phase == .running)
            }
        }
    }

    private func pickParentDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(
            fileURLWithPath: NSString(string: command.parentDir).expandingTildeInPath
        )
        if panel.runModal() == .OK, let url = panel.url {
            command.parentDir = url.path
        }
    }

    private func create() {
        guard command.validationError == nil else { return }
        phase = .running
        output = ""
        let cmd = command
        let script = NewProjectCommand.scriptURL(near: projects.sourceURL).path
        Task.detached(priority: .userInitiated) {
            // PATH 必须补全：GUI app 的环境里没有 /usr/local/bin，gh 会找不到。
            let result = Shell.run(
                "/bin/bash",
                cmd.arguments(scriptPath: script),
                timeout: 180,
                environment: ["PATH": NewProjectCommand.guiPATH]
            )
            let text = Self.stripANSI(
                [result.stdout, result.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
            await MainActor.run {
                output = text
                phase = .finished(success: result.succeeded)
                // 脚本已把新项目写进 projects.yaml，重载后岛和主窗口同时看到。
                if result.succeeded { projects.load() }
            }
        }
    }

    /// 脚本输出带终端色码，GUI 里显示要剥掉。
    nonisolated static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression
        )
    }
}
