import HubProjects
import SwiftUI

/// 账号密码。
///
/// 和「共用密钥」的关系：**没有关系，而且必须看起来就没有关系。**
/// 那边的值故意写成明文文件给 AI 用；这里的密码只给人看。
/// 两个面板长得越像，用户越可能把线上库的密码填错地方。
///
/// **这个视图只挂在主窗口上，绝不进灵动岛。** 岛是常驻在屏幕顶端的，
/// 任何在上面渲染过的东西都等于长期挂在别人眼前和截图工具面前。
struct CredentialsPane: View {
    @Bindable var credentials: CredentialStore
    @Bindable var projects: ProjectStore

    private enum Scope: Hashable {
        case project(String)
        case orphans
    }

    @State private var scope: Scope?
    @State private var revealed: (id: UUID, value: String)?
    @State private var editing: EditingTarget?
    @State private var flash: String?

    private struct EditingTarget: Identifiable {
        var id: UUID { credential.id }
        var credential: Credential
        var isNew: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "账号密码",
                subtitle: "本地和线上分开记。只给你自己看 —— 不写进任何文件，也不会交给 AI。"
            )
            VaultStateBanner(state: credentials.state)

            HStack(spacing: 0) {
                scopeList
                Divider()
                detail
            }
            Divider()
            bottomBar
        }
        .onAppear {
            if scope == nil, let first = projects.projects.first {
                scope = .project(ProjectKey.key(for: first))
            }
            reconcileMissingProjects()
        }
        .sheet(item: $editing) { target in
            CredentialSheet(
                credential: target.credential,
                isNew: target.isNew,
                onSave: { credential, password in
                    // 编辑时密码框留空 = 不改密码，不是改成空。
                    credentials.upsert(credential, password: password)
                }
            )
        }
    }

    /// 项目从 projects.yaml 里没了，把它的账号挪成「不属于任何项目」而不是删掉 ——
    /// 那可能是用户唯一一份密码记录。
    private func reconcileMissingProjects() {
        let alive = Set(projects.projects.map { ProjectKey.key(for: $0) })
        credentials.detachCredentials(
            ofMissingProjectKeys: Set(credentials.usedProjectKeys).subtracting(alive)
        )
    }

    // MARK: - 左边

    private var scopeList: some View {
        List(selection: $scope) {
            ForEach(projects.projects) { project in
                let key = ProjectKey.key(for: project)
                HStack {
                    Text(project.name).font(.system(size: 12))
                    Spacer()
                    let n = credentials.credentials.filter { $0.projectKey == key }.count
                    if n > 0 {
                        Text("\(n)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .tag(Scope.project(key))
            }
            if credentials.hasOrphans {
                Text("不属于任何项目").font(.system(size: 12)).tag(Scope.orphans)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 220)
    }

    private var currentProjectKey: String? {
        switch scope {
        case .project(let key): return key
        case .orphans, nil: return nil
        }
    }

    // MARK: - 右边

    @ViewBuilder
    private var detail: some View {
        let groups = credentials.grouped(projectKey: currentProjectKey)
        if groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("这里还没有记账号").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("加一条", action: startNew)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(groups, id: \.env) { group in
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Text(group.env.rawValue)
                                        .font(.system(size: 12, weight: .semibold))
                                    if group.env.isProduction {
                                        // 线上要一眼认出来。用错环境的账号去操作，
                                        // 是这类工具最容易造成的实际损失。
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(IslandTheme.danger)
                                    }
                                }
                                ForEach(group.items) { row($0) }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func row(_ credential: Credential) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(credential.label).font(.system(size: 12, weight: .medium))
                    if !credential.username.isEmpty {
                        Text(credential.username)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()

                // 展开的密码。一次只可能有一条 —— revealed 是单值不是集合。
                if revealed?.id == credential.id, let value = revealed?.value {
                    Text(value)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(IslandTheme.waiting.opacity(0.15),
                                    in: .rect(cornerRadius: 6, style: .continuous))
                } else {
                    Text("••••••••").font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Button("看一眼") { reveal(credential) }.font(.system(size: 11))
                Button("复制") { copy(credential) }.font(.system(size: 11))
                Button {
                    editing = EditingTarget(credential: credential, isNew: false)
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                Button(role: .destructive) {
                    credentials.remove(id: credential.id)
                    if revealed?.id == credential.id { revealed = nil }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if !credential.url.isEmpty || !credential.note.isEmpty {
                Text([credential.url, credential.note].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 动作

    private func reveal(_ credential: Credential) {
        Task { @MainActor in
            do {
                let value = try await credentials.password(for: credential.id)
                revealed = (credential.id, value)
                // 30 秒自动收起。人会看完就走开，屏幕不会。
                try? await Task.sleep(for: .seconds(30))
                if revealed?.id == credential.id { revealed = nil }
            } catch {
                show("没能验证身份，密码没有显示")
            }
        }
    }

    private func copy(_ credential: Credential) {
        Task { @MainActor in
            do {
                let value = try await credentials.password(for: credential.id, reason: "复制「\(credential.label)」的密码")
                Clipboard.copySecret(value)
                show("已复制，45 秒后自动清空剪贴板")
            } catch {
                show("没能验证身份，没有复制")
            }
        }
    }

    private func startNew() {
        editing = EditingTarget(
            credential: Credential(projectKey: currentProjectKey, label: ""),
            isNew: true
        )
    }

    private func show(_ text: String) {
        flash = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if flash == text { flash = nil }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("加一条", action: startNew)
                .disabled(!credentials.state.canWrite)
            if let flash {
                Text(flash).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("密码只存在加密文件里，不会写进 ~/.vibe-foreman，也不会给 AI")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// 新增/编辑一条账号。抄 `NewProjectSheet` 的排版。
private struct CredentialSheet: View {
    @State var credential: Credential
    let isNew: Bool
    /// password 传 nil = 不改密码。
    var onSave: (Credential, String?) -> Void

    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "新增账号" : "编辑账号")
                .font(.system(size: 16, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("名称").font(.system(size: 12))
                    TextField("线上后台", text: $credential.label).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("环境").font(.system(size: 12))
                    Picker("", selection: $credential.env) {
                        ForEach(CredentialEnv.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                GridRow {
                    Text("账号").font(.system(size: 12))
                    TextField("admin@example.com", text: $credential.username)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("密码").font(.system(size: 12))
                    SecureField(isNew ? "" : "留空表示不修改", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("地址").font(.system(size: 12))
                    TextField("https://…", text: $credential.url).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("备注").font(.system(size: 12))
                    TextField("", text: $credential.note).textFieldStyle(.roundedBorder)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    // 编辑时留空 = 保留原密码。不区分的话，用户改一下备注
                    // 就把密码清空了，而且要等到下次用的时候才发现。
                    onSave(credential, password.isEmpty && !isNew ? nil : password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(credential.label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 340)
    }
}
