import AppKit
import HubCore
import HubProbe
import HubProjects
import SwiftUI

/// 验收清单页。
///
/// ## 为什么不做二级分栏
///
/// 直觉写法是左边项目列表、右边清单。但主窗口的 sidebar 已经占掉 190–260pt，
/// 再切一列，清单那一栏就只剩三四百点宽 —— 要点文本本来就长，证据里还有文件路径，
/// 那个宽度下每一行都要折成三行，等于什么都看不清。
///
/// 所以改成：顶部一个项目选择器 + 一行汇报条，下面整宽的分组列表。
///
/// ## 汇报级
///
/// 列表每行只给三样：状态、要点文本（截断）、证据徽章。**点开单条才展开细节。**
/// 逐条证据和 diff 全文走「导出报告」——窗口这个宽度摊不开，硬摊只会让人不看。
struct AcceptancePane: View {
    let acceptance: AcceptanceStore
    let projects: ProjectStore
    let store: SessionStore
    let settings: VerifierSettings
    let verifier: AcceptanceVerifier
    @Bindable var watchdog: SessionWatchdog
    @Binding var selection: String?

    @State private var showProbes = false

    /// 正在跑验证的那一条。同时只允许跑一条 —— 并发跑 `swift build`
    /// 会互相抢构建目录锁，结果全是假失败。
    @State private var running: String?
    /// 正在往哪个会话推消息。防连点 —— 注入是往终端敲字，重复注入会串行叠加。
    @State private var notifying: String?

    /// 往终端注入文字的通道。和岛上「去终端回答」用的是同一条路。
    private let reply = TerminalReply()

    @State private var expanded: Set<String> = []
    @State private var draft = ""
    @State private var pickerOpen = false
    @State private var query = ""
    @State private var lane: AcceptanceLedger.Lane = .pending
    @State private var diff: DiffRequest?

    /// 「看改动」弹的那张 sheet 的内容。
    struct DiffRequest: Identifiable {
        let id = UUID()
        let path: String
        let itemText: String
        var patch: String?   // nil = 还在读
    }
    @FocusState private var searchFocused: Bool

    /// 选择器里要列的项目：**所有已登记项目**，有清单的排前面。
    ///
    /// 早先只列「已经有清单的项目」，结果一条清单都没有时选择器整个不渲染 ——
    /// 用户对着一个不知道往哪写的输入框。清单是按项目分的，那"当前是哪个项目"
    /// 就必须**任何时候都看得见**，而不是等有了数据才出现。
    private var pickerPaths: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in acceptance.projectPaths where seen.insert(path).inserted {
            result.append(path)
        }
        for path in projects.projects.map(\.expandedPath) where seen.insert(path).inserted {
            result.append(path)
        }
        // currentPath 可能两边都不在（比如会话跑在没登记的目录里），也得能选中。
        if let path = defaultPath, seen.insert(path).inserted { result.insert(path, at: 0) }
        return result
    }

    /// 当前在看哪个项目。
    ///
    /// **`selection` 优先，哪怕它还没有清单。** 用户从会话行点「清单」进来时，
    /// 那个项目通常一条要点都还没有；如果这时回退到"第一个有清单的项目"，
    /// 用户敲进去的第一条要点就会落到**别的项目**上 —— 清单挂错项目，这功能就废了。
    private var currentPath: String? { selection ?? defaultPath }

    /// 没选过时的默认项目：**当前有会话在跑的那个**。
    /// 你正在干的活通常就是你要验收的活，让你少点一次。
    private var defaultPath: String? {
        if let session = store.sessions.first {
            return AcceptanceStore.projectPath(forCWD: session.cwd, projects: projects)
        }
        return acceptance.projectPaths.first ?? projects.projects.first?.expandedPath
    }

    private var ledger: AcceptanceLedger? {
        currentPath.map { acceptance.ledger(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "验收",
                subtitle: "独立于 Claude 自述的需求清单。基线来自你的原话和你批准过的计划。"
            )

            if !pickerPaths.isEmpty { controls }
            watchdogBar
            sessionPromises

            if ledger?.items.isEmpty ?? true {
                ContentUnavailableView(
                    currentPath.map { "\(label(for: $0)) 还没有清单" } ?? "还没有项目",
                    systemImage: "checklist",
                    description: Text("在下面手动加一条，或等 Claude Hub 从你的需求里自动拆出来")
                )
                .frame(maxHeight: .infinity)
            } else {
                lanes
                list
            }

            composer
        }
        .sheet(item: $diff) { request in
            diffSheet(request)
        }
    }

    // MARK: - 点击回溯

    @ViewBuilder
    private func diffSheet(_ request: DiffRequest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.path)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                Text(request.itemText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)

            Divider()

            if let patch = request.patch {
                ScrollView([.vertical, .horizontal]) {
                    Text(patch.isEmpty ? "这个文件从基线到现在没有改动。" : patch)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Spacer()
                Button("关闭") { diff = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 760, height: 520)
    }

    /// 读某个文件从基线到现在的 diff。
    ///
    /// 在后台读：`git diff` 要 fork 一个进程，大仓库上能到几百毫秒，
    /// 放在主线程会让整个窗口卡一下。
    private func openDiff(path: String, item: AcceptanceItem) {
        guard let cwd = currentPath else { return }
        diff = DiffRequest(path: path, itemText: item.text, patch: nil)
        let since = item.baselineCommit
        Task.detached(priority: .userInitiated) {
            let patch = GitDiff.patch(cwd, since: since, paths: [path], limit: 200_000)
            await MainActor.run {
                // 用户可能已经关掉或点了别的文件 —— 只更新还在等的那一个。
                guard diff?.path == path else { return }
                diff?.patch = patch
            }
        }
    }

    // MARK: - 顶部：项目选择 + 汇报条

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            // 永远显示。清单是按项目分的，"现在是哪个项目"必须任何时候都看得见。
            //
            // 不用 Picker：项目有几十个，原生下拉是一条几十项的长列表，
            // 找一个项目要肉眼扫一遍。换成带搜索的弹出层。
            Button {
                query = ""
                pickerOpen = true
            } label: {
                HStack(spacing: 5) {
                    Text(currentPath.map { label(for: $0) } ?? "选择项目")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                projectSearch
            }

            if let ledger {
                Text(ledger.headline)
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(ledger.disputedCount > 0 ? IslandTheme.danger : .secondary)
            }

            Spacer()

            Button("导出报告") { export() }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .disabled(ledger?.items.isEmpty ?? true)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - 盯梢

    /// 会话观察者的开关和最近一次追问。
    ///
    /// 放在验收页而不是设置页：它和这一页是同一件事的两面 ——
    /// 清单管「要做什么」，盯梢管「有没有一直做下去」。而且它天然按项目走，
    /// 这一页本来就是项目作用域的。
    ///
    /// **最近一次追问必须显示出来。** 一个"在盯着"但从没说过话的盯梢，
    /// 和没开是一样的，而用户没法从开关上区分这两种。
    @ViewBuilder
    private var watchdogBar: some View {
        if let path = currentPath {
            let on = watchdog.isWatching(path)
            let recent = watchdog.lastNudge(for: path)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Toggle("盯梢：停了就追问", isOn: Binding(
                        get: { on },
                        set: { watchdog.setWatching($0, path) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12, weight: .medium))

                    if on {
                        // 两个数字分开显示：用户要能看出「通用的」和「从清单
                        // 当场生成的」是两回事，否则改了上面那个文本框却发现
                        // 问出来的问题对不上，会以为坏了。
                        Text("通用 \(watchdog.probeList(for: path).count) 条 + 清单 \(watchdog.generatedProbes(for: path).count) 条 · 交替问")
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(showProbes ? "收起清单" : "看/改清单") { showProbes.toggle() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }

                if on, let recent {
                    Text("上次追问 \(recent.at, style: .relative)前 · \(recent.sessionName)：\(recent.probe)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if showProbes {
                    TextEditor(text: Binding(
                        get: { watchdog.probeList(for: path).joined(separator: "\n") },
                        set: { watchdog.setProbes($0.components(separatedBy: "\n"), for: path) }
                    ))
                    .font(.system(size: 11))
                    .frame(height: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(.quaternary)
                    )
                    Text("一行一条。它每次停下来就问下一条，问完从头再来。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: - AI 答应的事做全了没

    /// 这个项目下每个在跑的会话，AI 自己列的 todo 完成情况。
    ///
    /// 单独一条，不混进下面的清单里：用户问的是「**这一轮**它答应的做全了没」，
    /// 而清单是按项目跨会话累积的，混在一起答不了这个问题。
    @ViewBuilder
    private var sessionPromises: some View {
        let sessions = store.sessions.filter {
            currentPath != nil
                && AcceptanceStore.projectPath(forCWD: $0.cwd, projects: projects) == currentPath
        }
        if !sessions.isEmpty, let path = currentPath {
            VStack(spacing: 4) {
                ForEach(sessions) { session in
                    let pending = acceptance.unfinishedAssistantTasks(
                        sessionId: session.sessionId, in: path
                    )
                    let total = acceptance.ledger(for: path).items.filter {
                        $0.sourceSessionId == session.sessionId && $0.origin == .assistantTask
                    }.count
                    if total > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: pending.isEmpty
                                ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(
                                    pending.isEmpty ? IslandTheme.shell : IslandTheme.waiting
                                )
                            Text(session.name ?? session.sessionId.prefix(8).description)
                                .font(.system(size: 12, weight: .medium))
                            Text(pending.isEmpty
                                ? "AI 答应的 \(total) 项都做完了"
                                : "AI 答应了 \(total) 项，还差 \(pending.count) 项")
                                .font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !pending.isEmpty {
                                Button(notifying == session.sessionId ? "已发" : "告知这个会话") {
                                    notify(session: session, pending: pending)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11, weight: .medium))
                                .disabled(notifying != nil)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    /// 把没做完的推回那个会话的终端。
    ///
    /// 走 `TerminalReply.send` 注入到对应 pane —— 不是发通知让用户自己切过去，
    /// 而是直接把话说到那个 Claude 面前。用户的原话：
    /// 「可以在这边交互的时候映射到对应的 session 里告知」。
    private func notify(session: AgentSession, pending: [AcceptanceItem]) {
        notifying = session.sessionId
        let lines = pending.prefix(8).map { "- \($0.text)" }.joined(separator: "\n")
        let more = pending.count > 8 ? "\n（另有 \(pending.count - 8) 项）" : ""
        let text = """
        【Claude Hub】你自己列的 todo 里这几项还没做完，逐条确认一下现在的状态：
        \(lines)\(more)
        """
        let reply = self.reply
        Task {
            _ = await reply.send(text: text, to: session.sessionId)
            try? await Task.sleep(for: .seconds(2))
            notifying = nil
        }
    }

    // MARK: - 项目搜索

    @ViewBuilder
    private var projectSearch: some View {
        VStack(spacing: 0) {
            TextField("搜索项目…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit {
                    // 回车直接选中唯一/第一个结果 —— 打两个字母就走，不用抬手去点。
                    if let first = filteredPaths.first { choose(first) }
                }
                .padding(8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredPaths, id: \.self) { path in
                        projectRow(path)
                    }
                    if filteredPaths.isEmpty {
                        Text("没有匹配的项目")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 280)
        // 弹出即聚焦搜索框：打开选择器的意图就是"我要找一个"，
        // 还要先点一下输入框等于白给一次点击。
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private func projectRow(_ path: String) -> some View {
        let ledger = acceptance.ledger(for: path)
        Button {
            choose(path)
        } label: {
            HStack(spacing: 6) {
                Text(label(for: path))
                    .font(.system(size: 12, weight: path == currentPath ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                // 需要关注的条数直接标出来，扫一眼就知道该去哪个项目。
                if ledger.disputedCount > 0 {
                    Text("\(ledger.disputedCount)")
                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(IslandTheme.danger)
                }
                if ledger.openCount > 0 {
                    Text("\(ledger.openCount)")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(IslandTheme.waiting)
                }
                if path == currentPath {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                }
            }
            .contentShape(.rect)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private func choose(_ path: String) {
        selection = path
        pickerOpen = false
        query = ""
    }

    /// 搜索结果。先做子串匹配，没命中再退到子序列匹配。
    ///
    /// 子序列那一档是给缩写用的：项目名普遍是 `demo-ios` / `demo-android`
    /// 这种长复合词，打 `nios` 就能定位比打全名快得多。但它**只在子串无结果时**
    /// 才启用 —— 子序列匹配太宽松，直接用会让精确输入也返回一堆噪音。
    private var filteredPaths: [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return pickerPaths }

        let direct = pickerPaths.filter {
            label(for: $0).lowercased().contains(needle) || $0.lowercased().contains(needle)
        }
        guard direct.isEmpty else { return direct }

        return pickerPaths.filter {
            AcceptancePane.isSubsequence(needle, of: label(for: $0).lowercased())
        }
    }

    /// `needle` 的每个字符是否按顺序出现在 `haystack` 里。
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle {
            var matched = false
            while let next = iterator.next() {
                if next == character { matched = true; break }
            }
            guard matched else { return false }
        }
        return true
    }

    // MARK: - 列表

    /// 分段切换。
    ///
    /// 带计数是刻意的：不带的话你得先点进去才知道那一段是不是空的，
    /// 而「疑似未做」这一段通常就是空的 —— 让人白点一次。
    @ViewBuilder
    private var lanes: some View {
        Picker("", selection: $lane) {
            ForEach(AcceptanceLedger.Lane.allCases) { item in
                Text("\(item.rawValue) \(ledger?.count(in: item) ?? 0)").tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var list: some View {
        let items = ledger?.items(in: lane) ?? []
        if items.isEmpty {
            ContentUnavailableView(
                "「\(lane.rawValue)」是空的",
                systemImage: lane == .disputed ? "checkmark.circle" : "tray",
                description: Text(
                    lane == .disputed ? "没有自报做完却在代码里找不到的项 —— 这是好事" : "换一段看看"
                )
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items) { row($0) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: AcceptanceItem) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    // 可点开的那一段。操作按钮放在它外面 —— 套在同一个
                    // onTapGesture 里的话，点「确认」会顺手把行也展开。
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Self.color(for: item.status))
                            .frame(width: 7, height: 7)

                        Text(item.text)
                            .font(.system(size: 13))
                            .lineLimit(expanded.contains(item.id) ? nil : 1)

                        Spacer(minLength: 6)

                        // 一条里塞了几件事必须在行上就看得见 —— 藏在展开区里
                        // 等于没标：用户不会为了看有没有分项去逐条展开。
                        if !item.parts.isEmpty {
                            Text("\(item.partsDone)/\(item.parts.count) 项")
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundStyle(
                                    item.partsDone == item.parts.count
                                        ? IslandTheme.shell : IslandTheme.waiting
                                )
                        }

                        // 问过 3 次都说没做 —— 多半是这条拆错了，不是它偷懒。
                        // 必须标出来：它已经被排除出注入了，不标的话就是安静地
                        // 消失，用户永远不知道有一条要点再也不会被问。
                        if item.likelyMisextracted {
                            Text("疑似误拆")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(IslandTheme.danger)
                                .help("问了 \(item.askCount) 次都回答没做，可能这条要点本身就拆偏了。看一眼，不对就划掉。")
                        }

                        Text(item.origin.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)

                        proofBadge(item)
                    }
                    .contentShape(.rect)
                    .onTapGesture { toggle(item.id) }

                    quickActions(item)
                }

                if expanded.contains(item.id) {
                    detail(item)
                }
            }
        }
    }

    /// 行内的人工确认。
    ///
    /// **必须在行上，不能只藏在展开区里。** 一份清单几十条，逐条展开再确认
    /// 根本清不动 —— 清不掉的清单会一直堆着，堆到用户不看它，
    /// 那时候这个功能就等于不存在了。
    ///
    /// 人工判定是终裁：勾了之后旁路复核再判什么都盖不掉（`applyAudit` 会跳过）。
    @ViewBuilder
    private func quickActions(_ item: AcceptanceItem) -> some View {
        HStack(spacing: 2) {
            if item.isSettledByUser {
                Button {
                    setStatus(.open, item)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("撤销，放回未验收")
            } else {
                Button {
                    setStatus(.accepted, item)
                } label: {
                    Image(systemName: "checkmark")
                }
                .help("确认做到了（人工判定，机器结论盖不掉）")

                Button {
                    setStatus(.dropped, item)
                } label: {
                    Image(systemName: "xmark")
                }
                .help("划掉，这条不做了")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    /// 证据徽章。**三档必须能一眼分开** —— 「仅自述」和「跑过」看起来一样的话，
    /// 这个功能就退化成了转述 Claude 的话。
    @ViewBuilder
    private func proofBadge(_ item: AcceptanceItem) -> some View {
        if item.evidence.isEmpty {
            Text("无证据")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else if item.hasProof {
            let ran = item.evidence.contains { if case .ran = $0 { return true } else { return false } }
            Label(ran ? "跑过" : "有改动", systemImage: ran ? "gearshape.fill" : "plusminus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IslandTheme.shell)
        } else {
            Label("仅自述", systemImage: "quote.bubble")
                .font(.system(size: 10))
                .foregroundStyle(IslandTheme.waiting)
        }
    }

    @ViewBuilder
    private func detail(_ item: AcceptanceItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 分项逐条勾。一条 todo 勾掉时，里面四件做了三件还是四件，
            // 只有摊开才看得出来 —— 而漏掉的往往正是最后那件。
            ForEach(Array(item.parts.enumerated()), id: \.offset) { index, part in
                Button {
                    togglePart(item, index)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: part.done ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11))
                            .foregroundStyle(part.done ? IslandTheme.shell : .secondary)
                        Text(part.text)
                            .font(.system(size: 12))
                            .strikethrough(part.done, color: .secondary)
                            .foregroundStyle(part.done ? .secondary : .primary)
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if !item.parts.isEmpty { Divider().padding(.vertical, 2) }

            if let acceptance = item.acceptance {
                Text("验收条件：\(acceptance)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                verifyControls(item, acceptance)
            }
            if let note = item.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                HStack(spacing: 5) {
                    Text(evidence.isProof ? "✅" : "○")
                        .font(.system(size: 10))
                    Text(evidence.shortLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    // 点文件看真实 diff —— 「点击回溯看看实际更新的」。
                    // 只有 .diff 有得看：自述里没有文件，跑命令的输出在报告里。
                    if case .diff(let path, _, _) = evidence {
                        Button("看改动") { openDiff(path: path, item: item) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10, weight: .medium))
                    }
                }
            }

            // 确认 / 划掉 已经在行上了（见 quickActions），这里只留删除 ——
            // 同一个动作在两处出现，用户会以为它们不是一回事。
            HStack {
                Spacer()
                Button("删除这条") { remove(item) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandTheme.danger)
            }
            .padding(.top, 2)
        }
        .padding(.leading, 15)
    }

    // MARK: - 实际功能证明（Hub 自己跑）

    /// 验收条件下面那一行控件。
    ///
    /// 三道闸的状态在这里全都要**说出来**，不能只显示一个能点的按钮：
    /// 用户得知道这条为什么能跑 / 为什么不能跑。一个默默不工作的按钮
    /// 比没有按钮更糟。
    @ViewBuilder
    private func verifyControls(_ item: AcceptanceItem, _ acceptance: String) -> some View {
        let check = AcceptanceVerifier.classify(acceptance)
        HStack(spacing: 8) {
            switch check {
            case .notACommand:
                Text("这条只能人工确认")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

            case .rejected(let reason):
                Label(reason, systemImage: "hand.raised.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandTheme.danger)

            case .allowed(let argv):
                let command = argv.joined(separator: " ")
                if !settings.enabled {
                    Text("总开关关着 —— 去设置里打开「自动跑验收命令」")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if acceptanceStoreAuthorized(command) {
                    Button(running == item.id ? "跑着…" : "现在验证") {
                        runVerification(item, command: command)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .disabled(running != nil)
                    Button("撤销授权") { revoke(command) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    // 命令原文原样显示 —— 授权的前提是看得见到底要跑什么。
                    Button("允许执行 `\(command)`") { authorize(command) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            Spacer()
        }
    }

    private func acceptanceStoreAuthorized(_ command: String) -> Bool {
        guard let path = currentPath else { return false }
        return acceptance.isAuthorized(command, in: path)
    }

    private func authorize(_ command: String) {
        guard let path = currentPath else { return }
        acceptance.authorize(command, in: path)
    }

    private func revoke(_ command: String) {
        guard let path = currentPath else { return }
        acceptance.revoke(command, in: path)
    }

    private func runVerification(_ item: AcceptanceItem, command: String) {
        guard let path = currentPath else { return }
        running = item.id
        let verifier = self.verifier
        let authorized = Set(acceptance.ledger(for: path).authorizedCommands)
        Task {
            let outcome = await verifier.verify(
                acceptance: item.acceptance, cwd: path, authorized: authorized
            )
            running = nil
            guard case .ran(let evidence) = outcome else { return }
            acceptance.recordVerification(evidence, forID: item.id, in: path)
            // 展开着才看得到结果。
            expanded.insert(item.id)
        }
    }

    // MARK: - 手动加一条

    @ViewBuilder
    private var composer: some View {
        HStack(spacing: 8) {
            // 占位符里带上项目名 —— 输入框和顶部选择器隔着整个列表，
            // 光标在这儿时看不见上面选的是谁。
            TextField(
                currentPath.map { "给「\(label(for: $0))」加一条要点…" } ?? "手动加一条要点…",
                text: $draft
            )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { addDraft() }
            Button("加入") { addDraft() }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 动作

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func togglePart(_ item: AcceptanceItem, _ index: Int) {
        guard let path = currentPath else { return }
        acceptance.togglePart(at: index, forID: item.id, in: path)
    }

    private func setStatus(_ status: AcceptanceItem.Status, _ item: AcceptanceItem) {
        guard let path = currentPath else { return }
        acceptance.setStatus(status, forID: item.id, in: path)
    }

    private func remove(_ item: AcceptanceItem) {
        guard let path = currentPath else { return }
        acceptance.remove(id: item.id, from: path)
        expanded.remove(item.id)
    }

    private func addDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let path = currentPath else { return }
        acceptance.add(AcceptanceItem(text: text, origin: .manual), to: path)
        selection = path
        draft = ""
    }

    private func label(for path: String) -> String {
        projects.projectName(forPath: path) ?? (path as NSString).lastPathComponent
    }

    /// 导出报告。报告即归档 —— 不做第二套渲染。
    private func export() {
        guard let path = currentPath else { return }
        let name = label(for: path)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "验收报告-\(name).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = acceptance.markdownReport(for: path, projectName: name)
        try? markdown.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func color(for status: AcceptanceItem.Status) -> Color {
        switch status {
        case .disputed: return IslandTheme.danger
        case .open: return IslandTheme.waiting
        case .claimed: return IslandTheme.busy
        case .confirmed, .accepted: return IslandTheme.shell
        case .dropped: return .secondary
        }
    }
}
