import Foundation

/// 极薄的外部命令封装。只用于确实没有 API 替代的场景：`tmux` 和 `osascript`。
///
/// 进程信息一律走 `ProcessTree`（sysctl），不要用这个去调 `ps`。
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String

        public var succeeded: Bool { status == 0 }
    }

    /// 同步执行并捕获输出。
    ///
    /// - Parameter timeout: 超时秒数。tmux 在 server 无响应时会挂住，
    ///   AppleScript 在目标 app 卡死时更会挂很久 —— 探测循环里必须有上界，
    ///   否则整个 UI 的刷新会被一个卡住的 osascript 拖死。
    /// - Parameter environment: 在继承的环境之上追加/覆盖的变量。
    ///   `StallJudge` 用它注入 `HUB_JUDGE=1` 来封死 hook 回环。
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 5,
        environment: [String: String] = [:]
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // /dev/null 而不是不设：子进程读 stdin 时会立刻拿到 EOF。
        // `claude -p` 在拿不到 stdin 时会干等 3 秒才继续，这里直接避掉。
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "\(error)")
        }

        // 必须在 waitUntilExit 之前把管道读干：管道缓冲区约 64KB，
        // 写满后子进程会阻塞在 write 上，而我们阻塞在 wait 上 —— 经典死锁。
        // 后台线程读取可以同时避免这个死锁和超时逻辑的竞争。
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "hub.shell.io", attributes: .concurrent)

        group.enter()
        queue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(5_000)
        }
        if process.isRunning {
            process.terminate()
            // 给 SIGTERM 一点时间，不行就硬杀，避免留下僵尸拖住管道读取线程。
            let hardDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < hardDeadline { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        process.waitUntilExit()
        group.wait()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// 执行 AppleScript。
    public static func osascript(_ source: String, timeout: TimeInterval = 8) -> Result {
        run("/usr/bin/osascript", ["-e", source], timeout: timeout)
    }
}
