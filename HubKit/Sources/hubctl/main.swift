import Darwin
import Foundation
import HubIPC

// hubctl —— Claude Code hook 的执行体。
//
// 为什么不用 bash：
// - 用 bash 拼 JSON 必须自己处理转义，而 tool_input 里带着任意 shell 命令，
//   这是实打实的注入隐患；
// - 本机 `nc` 没有 `-N`，没法在写完后半关闭连接，读应答会挂住；
// - python3 的可用性依赖用户环境，hook 是全局生效的东西，不能赌。
//
// 用法（由 ~/.claude/settings.json 配置）：
//   hubctl hook stop
//   hubctl hook notification
//   hubctl hook pretool
//   hubctl doctor          自检：socket 通不通
//
// **fail-open 是最高原则**：任何异常都放行。一个卡死的 hook 比一个漏审的命令
// 危害大得多 —— 前者会让用户的每一次工具调用都卡住 60 秒。

/// preToolUse 等待岛上决策的上限。见 `HookTimeouts` 里的超时阶梯说明 ——
/// 这个值必须**大于**服务端的决策超时，否则超时会变成放行而不是拒绝。
private let approvalTimeout = HookTimeouts.clientRead

/// 从 stdin 读 hook 的 JSON。
private func readStdin() -> [String: Any]? {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func string(_ dict: [String: Any], _ key: String) -> String? {
    (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
}

/// 构造事件。补上 Claude 不提供但我们需要的环境信息。
private func makeEvent(kind: HookEvent.Kind, payload: [String: Any]) -> HookEvent {
    let env = ProcessInfo.processInfo.environment

    var toolSummary: String?
    var toolInputJSON: String?
    if let toolName = string(payload, "tool_name"),
       let input = payload["tool_input"] as? [String: Any] {
        toolSummary = RiskClassifier.summarize(toolName: toolName, input: input)

        // 交互类工具（选择题 / 计划审批）要把完整 tool_input 带给岛上渲染。
        // 上限 256KB：socket 是单行协议（1MB 上限），一份超长 plan 不值得
        // 把整条链路撑爆 —— 超限就不带，服务端会降级成"去终端回答"。
        if AgentPromptPayload.interactiveTools.contains(toolName),
           let data = try? JSONSerialization.data(withJSONObject: input),
           data.count <= 262_144 {
            toolInputJSON = String(data: data, encoding: .utf8)
        }
    }

    return HookEvent(
        kind: kind,
        requestId: UUID().uuidString,
        sessionId: string(payload, "session_id") ?? "",
        cwd: string(payload, "cwd") ?? FileManager.default.currentDirectoryPath,
        transcriptPath: string(payload, "transcript_path"),
        permissionMode: string(payload, "permission_mode"),
        lastAssistantMessage: string(payload, "last_assistant_message"),
        stopReason: string(payload, "stop_reason"),
        stopHookActive: payload["stop_hook_active"] as? Bool,
        promptText: string(payload, "prompt"),
        notificationType: string(payload, "notification_type"),
        message: string(payload, "message"),
        toolName: string(payload, "tool_name"),
        toolSummary: toolSummary,
        toolUseId: string(payload, "tool_use_id"),
        toolInputJSON: toolInputJSON,
        // $TMUX_PANE 是 tmux 注入到每个 pane 环境里的 pane id。
        // 旧实现用 `tmux display-message -p '#W'` 且没带 -t，拿的是当前 active
        // 窗口而不是自己所在的窗口 —— 用户切个 tab 就归错项目了。读环境变量没这个问题。
        tmuxPane: env["TMUX_PANE"],
        clientPid: getpid()
    )
}

/// PreToolUse 的应答。输出什么、什么时候不输出，见 `HookDecision.hookOutputJSON()`。
private func emitDecision(_ decision: HookDecision) {
    if let text = decision.hookOutputJSON() {
        print(text)
    }
}

/// Hub 自己起的 `claude -p`（见 `StallJudge`）绝对不能再触发 hook。
///
/// 否则就是 hook → Hub → `claude -p` → hook 的无限回环：每判定一次就多生出
/// 一个会话，几轮之后把机器跑满。
///
/// **这道防线不依赖 Claude CLI 的任何行为开关。** 实测 `--setting-sources ''`
/// 并不能阻止 user 级 hooks 加载（本机 8 个会话同时在跑，靠 hubctl 的 atime
/// 做间接探测全是噪音，最后是靠这里的 trace 文件才测出来的），
/// 所以自己这一侧的早退是唯一保证有效的做法。
///
/// 顺带提供 `HUB_TRACE`：指向一个文件路径时，每次执行都追加一行。
/// 这是唯一能把"我起的那个 claude"和"用户另外七个会话"区分开的探针 ——
/// 环境变量会被子进程继承，而别人的会话没有这个变量。
private func guardAgainstJudgeLoop(_ name: String) {
    let env = ProcessInfo.processInfo.environment
    let isJudge = env["HUB_JUDGE"] == "1"

    if let trace = env["HUB_TRACE"], !trace.isEmpty {
        let line = "\(Date().timeIntervalSince1970) \(name) judge=\(isJudge)\n"
        if let handle = FileHandle(forWritingAtPath: trace) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: trace, atomically: true, encoding: .utf8)
        }
    }

    guard isJudge else { return }
    if env["HUB_DEBUG"] == "1" {
        FileHandle.standardError.write(Data("hubctl：HUB_JUDGE=1，跳过不上报\n".utf8))
    }
    // 什么都不输出就是放行。judge 用的会话本来也不该被审批拦。
    exit(0)
}

private func runHook(_ name: String) -> Int32 {
    guardAgainstJudgeLoop(name)

    let kind: HookEvent.Kind
    switch name {
    case "stop": kind = .stop
    case "notification", "notify": kind = .notification
    case "pretool", "pretooluse": kind = .preToolUse
    case "sessionend": kind = .sessionEnd
    case "userprompt", "userpromptsubmit": kind = .userPromptSubmit
    case "sessionstart": kind = .sessionStart
    case "posttool", "posttooluse": kind = .postToolUse
    case "subagentstop": kind = .subagentStop
    case "precompact": kind = .preCompact
    default:
        FileHandle.standardError.write(Data("未知的 hook 类型：\(name)\n".utf8))
        return 0   // 仍然放行
    }

    guard let payload = readStdin() else { return 0 }
    let event = makeEvent(kind: kind, payload: payload)

    let result = HubSocketClient.send(
        event,
        // 和服务端共用同一个判断，见 Kind.expectsDecision 上的事故说明。
        waitForDecision: kind.expectsDecision,
        // Stop 走独立的短阶梯：它挡在**每一次收工**前面，
        // 用 75 秒会让 Hub 一卡住用户就永远收不了工。
        timeout: kind == .stop ? HookTimeouts.stopRead : approvalTimeout
    )

    // Stop 的应答和 PreToolUse **方向相反**，单独处理。
    //
    // PreToolUse 的 .noResponse 要保守拒绝（服务端认为该拦，只是没答上来）；
    // Stop 的一切异常都必须什么都不输出 = 正常收工。写反的话 Hub 一出问题
    // 所有会话都再也停不下来 —— 比"少提醒一次验收"严重得多。
    if kind == .stop {
        if case .decided(let decision) = result, let text = decision.stopOutputJSON() {
            print(text)
        }
        return 0
    }

    guard kind == .preToolUse else { return 0 }

    // 排障开关：HUB_DEBUG=1 时把收到的结果打到 stderr。
    // stderr 不会被 Claude 当成 hook 的决策输出，所以开着也不影响行为。
    if ProcessInfo.processInfo.environment["HUB_DEBUG"] == "1" {
        FileHandle.standardError.write(Data("hubctl 收到：\(result)\n".utf8))
    }

    switch result {
    case .decided(let decision):
        emitDecision(decision)

    case .unreachable:
        // Hub 没运行 —— 这次调用压根没被审查过。放行。
        // 不能因为工具没开就让用户的每条命令都失败。
        break

    case .noResponse:
        // 连上了、发出去了，但服务端没在 75 秒内回应。
        //
        // 关键推断：服务端对非高风险操作是**立即**应答的，能走到这里说明
        // 它认为这次操作值得拦截，只是决策环节出了问题。这种情况必须拒绝 ——
        // 拒绝可恢复（Claude 会告诉用户并可重试），放行不可逆。
        emitDecision(
            HookDecision(verdict: .deny, reason: "Claude Hub 未能完成审批，已保守拒绝")
        )

    case .acknowledged:
        break
    }
    return 0
}

private func runDoctor() -> Int32 {
    let path = HubSocket.path
    print("socket 路径：\(path)")
    print("路径长度：\(path.utf8.count) / \(HubSocket.maxPathLength) 字节")
    print("socket 文件存在：\(FileManager.default.fileExists(atPath: path) ? "是" : "否")")

    if HubSocketClient.isHubRunning() {
        print("连接测试：✓ Claude Hub 正在运行")
        return 0
    }
    print("连接测试：✗ 连不上（Claude Hub 没运行，hook 会全部放行）")
    return 1
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "hook":
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("""
        用法：hubctl hook <stop|notification|pretool|posttool|sessionstart\
        |sessionend|userprompt|subagentstop|precompact>

        """.utf8))
        exit(0)
    }
    exit(runHook(args[1]))
case "doctor":
    exit(runDoctor())
default:
    print("用法：hubctl <hook <类型> | doctor>")
    exit(0)
}
