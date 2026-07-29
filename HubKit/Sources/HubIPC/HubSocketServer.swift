import Darwin
import Foundation
import HubCore

/// Hub 侧的 socket 服务端。
///
/// 每条连接的生命周期：hubctl 连上 → 发一行事件 JSON → 服务端处理
/// →（仅 preToolUse）回一行决策 JSON → 关闭。
///
/// 连接短、并发低，所以每条连接用一个阻塞的处理块跑在并发队列上就够了，
/// 不需要引入 async 事件循环。
public final class HubSocketServer: @unchecked Sendable {

    /// 事件处理器。返回值只有 `preToolUse` 会被用到。
    ///
    /// 处理器可能被长时间阻塞（审批要等用户点击），所以它跑在自己的连接线程上，
    /// 不会挡住其他连接。
    public typealias Handler = @Sendable (HookEvent) -> HookDecision?

    private let path: String
    private let handler: Handler
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "hub.ipc.accept")
    private let workQueue = DispatchQueue(label: "hub.ipc.work", attributes: .concurrent)

    public init(path: String = HubSocket.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let fd = try UnixSocket.listen(at: path)
        listenFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFd = -1
        unlink(path)
    }

    private func acceptOne() {
        let clientFd = accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return }

        workQueue.async { [handler] in
            defer { close(clientFd) }

            // 读事件本身要有上界：hubctl 连上却不发数据（被 SIGSTOP 了之类）
            // 不该永久占住一个工作线程。
            guard let line = UnixSocket.readLine(fd: clientFd, timeout: 10),
                  let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(HookEvent.self, from: data)
            else { return }

            let decision = handler(event)

            guard event.kind == .preToolUse else { return }
            let payload = decision ?? .allow
            if let encoded = try? JSONEncoder().encode(payload),
               let text = String(data: encoded, encoding: .utf8) {
                HubLog.ipc.notice("回写决策 \(text, privacy: .public)")
                UnixSocket.writeLine(fd: clientFd, text)
            }
        }
    }
}

/// 发送结果。
///
/// 「连不上」和「连上了但没回应」必须区分开，因为两者的安全默认值是相反的：
/// - 连不上 = Hub 没运行 = 这次调用压根没被审查过 → **放行**（fail-open，
///   不能因为 Hub 没开就让用户的每个命令都失败）；
/// - 连上了但没回应 = Hub 认为这次操作值得拦截，但决策环节出了问题
///   → **拒绝**（拒绝可恢复，放行不可逆）。
public enum HookSendResult: Sendable {
    /// 服务端明确给了结论。
    case decided(HookDecision)
    /// 服务端收下了但不需要应答（非 preToolUse 事件）。
    case acknowledged
    /// 连不上 —— Hub 没运行。
    case unreachable
    /// 连上了、发出去了，但超时没等到应答。
    case noResponse
}

/// hubctl 侧的客户端。
public enum HubSocketClient {

    /// 发事件；`preToolUse` 会等决策。
    public static func send(
        _ event: HookEvent,
        path: String = HubSocket.path,
        waitForDecision: Bool,
        timeout: TimeInterval
    ) -> HookSendResult {
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8)
        else { return .unreachable }

        guard let fd = try? UnixSocket.connect(to: path) else { return .unreachable }
        defer { close(fd) }

        guard UnixSocket.writeLine(fd: fd, line) else { return .unreachable }
        guard waitForDecision else { return .acknowledged }

        guard let response = UnixSocket.readLine(fd: fd, timeout: timeout),
              let responseData = response.data(using: .utf8),
              let decision = try? JSONDecoder().decode(HookDecision.self, from: responseData)
        else { return .noResponse }

        return .decided(decision)
    }

    /// Hub 是否在运行。用连接探测而不是查进程 —— 进程活着但 socket 没起来
    /// （比如刚启动还没 bind）同样应该算"不可用"。
    public static func isHubRunning(path: String = HubSocket.path) -> Bool {
        guard let fd = try? UnixSocket.connect(to: path) else { return false }
        close(fd)
        return true
    }
}
