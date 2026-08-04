import AppKit
import HubProbe
import HubProjects
import SwiftUI

/// 主窗口的「克隆项目」表单：从绑定的 gh 账号列出仓库点选，或手动贴地址。
/// 真正干活的是 scripts/clone-project.sh（gh 登录态直接可拉私有仓）。
struct CloneProjectSheet: View {
    let projects: ProjectStore
    /// 主窗口持有的共享实例：带磁盘缓存，打开即显示上次列表，后台静默刷新。
    let git: GitAccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var command = CloneCommand()
    @State private var repoFilter = ""
    /// nil = 不按 owner 过滤。
    @State private var ownerFilter: String?
    @State private var phase: Phase = .editing
    @State private var output = ""

    private enum Phase: Equatable {
        case editing
        case running
        case finished(success: Bool)
    }

    private var filteredRepos: [RemoteRepo] {
        var list = git.repos
        if let ownerFilter {
            list = list.filter { $0.nameWithOwner.hasPrefix(ownerFilter + "/") }
        }
        guard !repoFilter.isEmpty else { return list }
        let needle = repoFilter.lowercased()
        return list.filter { $0.nameWithOwner.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("克隆项目")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                accountBadge
            }

            if phase == .editing {
                repoPicker
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("仓库")
                    TextField("owner/repo 或 git 地址", text: $command.repo)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("克隆到")
                    HStack(spacing: 6) {
                        TextField("~/Documents/code", text: $command.parentDir)
                            .textFieldStyle(.roundedBorder)
                        Button("选…") { pickParentDir() }
                    }
                }
                GridRow {
                    Text("目录名")
                    TextField("留空 = \(command.derivedName.isEmpty ? "仓库名" : command.derivedName)",
                              text: $command.nameOverride)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .disabled(phase == .running)

            if phase != .editing {
                outputView
            }

            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 560, height: 500)
        .onAppear { git.refresh() }
    }

    /// 账号切换器。多账号时这是关键入口 —— gh 只用**活跃账号**的凭据，
    /// 不切过去就看不见、也拉不了另一个账号的私有仓。
    private var accountBadge: some View {
        Group {
            if git.accounts.isEmpty {
                if let diagnostic = git.diagnostic {
                    Label(diagnostic, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            } else if git.accounts.count == 1, let only = git.accounts.first {
                Label("\(only.login) · \(only.host)",
                      systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(git.accounts) { account in
                        Button {
                            ownerFilter = nil
                            git.switchTo(account)
                        } label: {
                            if account.active {
                                Label("\(account.login) · \(account.host)", systemImage: "checkmark")
                            } else {
                                Text("\(account.login) · \(account.host)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if git.isSwitching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                        }
                        Text(git.activeAccount.map { "\($0.login) · \($0.host)" } ?? "选择账号")
                        Text("(\(git.accounts.count))")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(git.isSwitching)
                .help("切换 gh 活跃账号；克隆用的就是这个账号的凭据")
            }
        }
    }

    /// owner 筛选标签（个人 + 各组织）。一个账号能看到十几个组织时，
    /// 光靠搜索框要记得住组织名才行。
    @ViewBuilder
    private var ownerChips: some View {
        let owners = git.owners
        if owners.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chip(title: "全部 \(git.repos.count)", selected: ownerFilter == nil) {
                        ownerFilter = nil
                    }
                    ForEach(owners, id: \.name) { owner in
                        chip(title: "\(owner.name) \(owner.count)",
                             selected: ownerFilter == owner.name) {
                            ownerFilter = ownerFilter == owner.name ? nil : owner.name
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
        }
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    selected ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.05),
                    in: .capsule
                )
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    /// 账号可及的仓库列表（含组织仓），点一行填进仓库输入框。
    private var repoPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("搜索仓库（含组织）…", text: $repoFilter)
                    .textFieldStyle(.roundedBorder)
                if git.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let refreshed = git.lastRefreshed {
                    Text(refreshed, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            ownerChips
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredRepos) { repo in
                        Button {
                            command.repo = repo.nameWithOwner
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(repo.nameWithOwner)
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer(minLength: 0)
                                if command.repo == repo.nameWithOwner {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                command.repo == repo.nameWithOwner
                                    ? Color.accentColor.opacity(0.15) : .clear,
                                in: .rect(cornerRadius: 5)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    // 只在完全没数据时占位；有缓存时刷新是无感的。
                    if git.repos.isEmpty {
                        Text(git.isRefreshing
                            ? "加载仓库列表…"
                            : (git.diagnostic ?? "没有拉到仓库列表，可直接在下面贴地址"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
            }
            .frame(height: 170)
            .background(Color.black.opacity(0.04), in: .rect(cornerRadius: 6))
        }
    }

    private var outputView: some View {
        ScrollView {
            Text(output.isEmpty ? "执行中…" : output)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxHeight: 150)
        .background(Color.black.opacity(0.05), in: .rect(cornerRadius: 6))
    }

    private var buttons: some View {
        HStack {
            if case .finished(let success) = phase, success {
                Label("已克隆并加入项目列表", systemImage: "checkmark.circle.fill")
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
                Button(phase == .running ? "克隆中…" : "克隆") { clone() }
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

    private func clone() {
        guard command.validationError == nil else { return }
        phase = .running
        output = ""
        let cmd = command
        let script = CloneCommand.scriptURL(near: projects.sourceURL).path
        Task.detached(priority: .userInitiated) {
            let result = Shell.run(
                "/bin/bash",
                cmd.arguments(scriptPath: script),
                timeout: 600,
                environment: ["PATH": NewProjectCommand.guiPATH]
            )
            let text = NewProjectSheet.stripANSI(
                [result.stdout, result.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
            await MainActor.run {
                output = text
                phase = .finished(success: result.succeeded)
                if result.succeeded { projects.load() }
            }
        }
    }
}
