import HubProjects
import SwiftUI

/// 共用密钥。
///
/// 界面上要一直说清楚一件事：**这里的值会被写成明文文件，就是给 AI 用的。**
/// 这不是免责声明，是这个功能的定义 —— 用户如果以为这里和「账号密码」是一回事，
/// 就会把线上数据库的密码填进来。
struct SecretsPane: View {
    @Bindable var secrets: SharedSecretStore
    @Bindable var projects: ProjectStore

    @State private var selection: UUID?
    @State private var revealed: Set<UUID> = []
    @State private var newGroupName = ""
    @State private var copied: String?

    private var selectedGroup: SecretGroup? {
        secrets.groups.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "共用密钥",
                subtitle: "一处配好，勾给要用的项目。值会写成明文 .env 文件供 AI 使用。"
            )
            VaultStateBanner(state: secrets.state)

            HStack(spacing: 0) {
                groupList
                Divider()
                detail
            }
            Divider()
            materializationBar
        }
        .onAppear { secrets.refresh(projects: projects.projects) }
        .onChange(of: projects.projects) { _, new in secrets.refresh(projects: new) }
    }

    // MARK: - 左边：组

    private var groupList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(secrets.groups.sorted { $0.name < $1.name }) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.system(size: 12, weight: .medium))
                        Text("\(group.entries.count) 条 · \(group.projectKeys.count) 个项目")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .tag(group.id)
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 6) {
                TextField("新建组（飞书、领星…）", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit(addGroup)
                Button("加", action: addGroup)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
        }
        .frame(width: 220)
    }

    private func addGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        selection = secrets.addGroup(name: name).id
        newGroupName = ""
    }

    // MARK: - 右边：详情

    @ViewBuilder
    private var detail: some View {
        if let group = selectedGroup {
            ScrollView {
                VStack(spacing: 12) {
                    entriesCard(group)
                    projectsCard(group)
                    dangerCard(group)
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("左边选一个组，或者新建一个").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func entriesCard(_ group: SecretGroup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                EditableText(placeholder: "组名", value: group.name) { new in
                    var g = group; g.name = new; secrets.update(g)
                }
                EditableText(placeholder: "备注（会写进 .env 的注释里）", value: group.note) { new in
                    var g = group; g.note = new; secrets.update(g)
                }
                Divider()
                ForEach(group.entries) { entry in
                    entryRow(entry, in: group)
                }
                NewEntryRow { key, value in
                    secrets.addEntry(to: group.id, key: key, value: value)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: SecretEntry, in group: SecretGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                EditableText(placeholder: "KEY", value: entry.key, monospaced: true) { new in
                    var e = entry; e.key = new; secrets.update(entry: e, in: group.id)
                }
                .frame(width: 200)

                SecretValueField(
                    value: entry.value,
                    revealed: Binding(
                        get: { revealed.contains(entry.id) },
                        set: { show in
                            if show { revealed.insert(entry.id) } else { revealed.remove(entry.id) }
                        }
                    )
                ) { new in
                    var e = entry; e.value = new; secrets.update(entry: e, in: group.id)
                }

                Button {
                    Clipboard.copySecret(entry.value)
                    flash("已复制 \(entry.key) 的值")
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    // 文件里的转义（含单引号的值会走 _B64）不一定是用户想要的形状，
                    // 所以永远留一条拿原始值的路。
                    .help("复制原始值")

                Button(role: .destructive) {
                    secrets.removeEntry(id: entry.id, from: group.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if !SecretEntry.isValidKey(entry.key) {
                warn("「\(entry.key)」不是合法的环境变量名，不会写进 .env")
            } else if entry.isUnwritable {
                warn("值里有 NUL 字节，环境变量装不下，不会写进 .env")
            } else if entry.needsBase64 {
                warn("值里有单引号，会写成 \(entry.key)_B64（用 base64 -d 还原）")
            }
        }
    }

    private func warn(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 10))
            .foregroundStyle(IslandTheme.waiting)
    }

    // MARK: - 项目绑定 + 路径

    private func projectsCard(_ group: SecretGroup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("哪些项目用这一组")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(projects.projects) { project in
                    projectRow(project, group: group)
                }
                if projects.projects.isEmpty {
                    Text("projects.yaml 里还没有项目").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func projectRow(_ project: Project, group: SecretGroup) -> some View {
        let bound = secrets.isBound(group, to: project)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { bound },
                set: { secrets.setBinding(groupID: group.id, project: project, bound: $0) }
            )) {
                Text(project.name).font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            Spacer()

            if bound {
                Button("复制路径") {
                    Clipboard.copy(secrets.envFilePath(for: project))
                    flash("路径已复制")
                }
                .font(.system(size: 11))

                Button("复制给 AI 的话") {
                    Clipboard.copy(secrets.aiPrompt(for: project))
                    flash("已复制 —— 里面写明了用 source 而不是 Read")
                }
                .font(.system(size: 11))
                // 复制裸路径的下场是 AI 用 Read 打开它，密钥就进了
                // ~/.claude/projects/*.jsonl（0644、永久、每轮重发），
                // 而且 Hub 自己的验收清单也会抄一份。这段话带 source 用法和禁令。
                .help("带用法和禁令的一段话，比直接给路径安全")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: secrets.envFilePath(for: project))]
                    )
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("在 Finder 里看")
            }
        }
    }

    private func dangerCard(_ group: SecretGroup) -> some View {
        Card {
            HStack {
                Text("删掉这一组").font(.system(size: 12))
                Spacer()
                Button("删除", role: .destructive) {
                    secrets.removeGroup(id: group.id)
                    selection = nil
                }
                .font(.system(size: 11))
            }
        }
    }

    // MARK: - 底部：物化状态

    private var materializationBar: some View {
        HStack(spacing: 12) {
            Toggle("物化到磁盘", isOn: $secrets.materializeEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 11))
                // 关掉之后磁盘上就真的一份明文都没有了 —— 权威副本是加密的。
                .help("关掉之后 ~/.vibe-foreman/env 会被清空，AI 就读不到任何东西了")

            if let copied {
                Label(copied, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(IslandTheme.shell)
            } else {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .failed(let reason) = secrets.lastOutcome {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(IslandTheme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// 「用完即焚」没做，做的是「一直看得见」——
    /// 消费方是非交互的 agent，没人能判断它「用完了」，
    /// 定时删只会造成 agent 第二次 source 失败然后自己发挥。
    /// 可见 + 可撤销比短暂有用得多。
    private var statusText: String {
        let n = secrets.materializedFileCount
        return n == 0 ? "磁盘上没有明文密钥" : "当前有 \(n) 个项目的密钥在磁盘上"
    }

    private func flash(_ text: String) {
        copied = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if copied == text { copied = nil }
        }
    }
}

/// 「加一条」的行内输入。抄 `AcceptancePane` 的 composer 写法。
private struct NewEntryRow: View {
    var onAdd: (String, String) -> Void
    @State private var key = ""
    @State private var value = ""

    private var canAdd: Bool { SecretEntry.isValidKey(key) }

    var body: some View {
        HStack(spacing: 6) {
            TextField("NEW_KEY", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 200)
            SecureField("值", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(add)
            Button("加入", action: add).disabled(!canAdd)
        }
    }

    private func add() {
        guard canAdd else { return }
        onAdd(key, value)
        key = ""
        value = ""
    }
}
