import Foundation

/// 极薄的外部命令封装。只用于确实没有 API 替代的场景：`tmux` 和 `osascript`。
///
/// 进程信息一律走 `ProcessTree`（sysctl），不要用这个去调 `ps`。
public enum Shell {

    /// 一次外部命令的结果。
    ///
    /// ## 为什么要区分「没跑起来」和「跑了但失败」
    ///
    /// 早先这里只有 `succeeded`，于是三件完全不同的事塌缩成了同一个 false：
    /// ① 进程压根没 fork 起来（fd 耗尽 / 可执行文件不在）；
    /// ② 跑起来了但超时被我们自己杀掉；
    /// ③ 正常跑完、命令自己返回非 0。
    ///
    /// 只有 ③ 才是「命令给出了答案，答案是否定的」。①② 是**没有答案**。
    /// 把没有答案当成否定答案，是本仓库真实发生过的一类故障的共同根源：
    /// `tmux has-session` 没跑起来 → 被读成「session 不存在」→ 去建重名 session；
    /// `tmux list-clients` 没跑起来 → 被读成「没有终端连着」→ 回收器去杀 pane。
    /// **一个探测器必须能说"我不知道"。**
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String

        /// 进程有没有真的被 fork 起来。false 表示 `Process.run()` 抛了错，
        /// `status` / `stdout` / `stderr` 全都不代表命令的意见。
        public let launched: Bool

        /// 是不是被超时逻辑打死的。true 同样表示命令没来得及给出意见。
        public let timedOut: Bool

        public var succeeded: Bool { status == 0 }

        /// 命令是否真的表了态（跑起来了、也没被我们打断）。
        /// 判定类调用应该先问这个，再看 `succeeded`。
        public var answered: Bool { launched && !timedOut }

        public init(
            status: Int32,
            stdout: String,
            stderr: String,
            launched: Bool = true,
            timedOut: Bool = false
        ) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
            self.launched = launched
            self.timedOut = timedOut
        }

        /// 排障用的一行摘要。落日志时用，别自己拼。
        public var diagnostic: String {
            if !launched { return "spawn 失败: \(stderr.trimmed())" }
            if timedOut { return "超时被终止 (status=\(status))" }
            let tail = stderr.trimmed()
            return tail.isEmpty ? "status=\(status)" : "status=\(status) stderr=\(tail)"
        }
    }

    /// 同时在跑的子进程上限。
    ///
    /// **这不是性能优化，是防 fd 耗尽。** GUI app 从 launchd 继承的
    /// `RLIMIT_NOFILE` 软上限是 **256**（终端里跑测试永远复现不出来，
    /// 因为 shell 早把它抬上去了）。每次调用要占 2 个 Pipe = 4 个 fd，
    /// 而这个 app 有 5 个轮询定时器和 40+ 个项目要轮询 ——
    /// 实测 fd 占用能冲到 251/256。撞顶之后 `Process.run()` 抛 EMFILE，
    /// 所有探测同时开始返回"没有答案"，上面 `Result` 注释里那两类故障
    /// 就是这么来的。
    ///
    /// 单纯抬高 rlimit 不够：那只是把天花板推高，尖峰还在。这里封死尖峰。
    ///
    /// 上限取 24 而不是更小：`AcceptanceVerifier` 会在这里跑 `swift test` /
    /// `npm run build`，那是分钟级的。槽位给太少的话，几个构建就能把
    /// 界面刷新用的探测全饿死 —— 换来一个"界面卡住"的新故障。
    /// 24 × 4 fd ≈ 96，离抬高后的上限还很远。
    private static let slots = DispatchSemaphore(value: 24)

    /// 同步执行并捕获输出。
    ///
    /// - Parameter timeout: 超时秒数。tmux 在 server 无响应时会挂住，
    ///   AppleScript 在目标 app 卡死时更会挂很久 —— 探测循环里必须有上界，
    ///   否则整个 UI 的刷新会被一个卡住的 osascript 拖死。
    /// - Parameter environment: 在继承的环境之上追加/覆盖的变量。
    ///   `StallJudge` 用它注入 `HUB_JUDGE=1` 来封死 hook 回环。
    /// - Parameter currentDirectory: 子进程的工作目录。
    ///   验收命令（`swift test` / `npm run build`）必须在项目目录里跑，
    ///   否则找不到 Package.swift / package.json。
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 5,
        environment: [String: String] = [:],
        currentDirectory: String? = nil
    ) -> Result {
        slots.wait()
        defer { slots.signal() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
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

        // 读端必须显式关，不能等 ARC。
        // `readDataToEndOfFile()` 读到 EOF 也不关 fd，而释放时机一旦落到
        // 下一次 autorelease pool，尖峰期就会多压几十个 fd 在上限上。
        func closePipes() {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }

        do {
            try process.run()
        } catch {
            // 早退路径同样要关 —— 这里原先直接 return，两个 Pipe 就那么挂着，
            // 而这条路径恰恰只在 fd 已经不够用的时候才会走到。
            closePipes()
            return Result(
                status: -1, stdout: "", stderr: "\(error)",
                launched: false, timedOut: false
            )
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

        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(5_000)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            // 给 SIGTERM 一点时间，不行就硬杀，避免留下僵尸拖住管道读取线程。
            let hardDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < hardDeadline { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        process.waitUntilExit()
        group.wait()
        closePipes()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            launched: true,
            timedOut: timedOut
        )
    }

    /// 执行 AppleScript。
    public static func osascript(_ source: String, timeout: TimeInterval = 8) -> Result {
        run("/usr/bin/osascript", ["-e", source], timeout: timeout)
    }
}

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
