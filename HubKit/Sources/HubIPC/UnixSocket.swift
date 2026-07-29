import Darwin
import Foundation

/// POSIX Unix domain socket 的薄封装。
///
/// 为什么用 socket 而不是文件轮询（旧实现是往 `/tmp/hub-signals/events/` 丢 JSON）：
/// - 对端断开可以感知 —— Claude 进程死了，挂起的审批卡能自动撤掉；
/// - 连不上就等于"Hub 没在跑"，零歧义，hubctl 可以立刻放行而不是傻等；
/// - 审批需要**双向**通信，文件方案得靠两边轮询，延迟和竞态都难处理。
enum UnixSocket {

    enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case createFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case connectFailed(Int32)

        var description: String {
            switch self {
            case .pathTooLong(let p):
                return "socket 路径超过 \(HubSocket.maxPathLength) 字节：\(p)"
            case .createFailed(let e): return "socket() 失败：\(String(cString: strerror(e)))"
            case .bindFailed(let e): return "bind() 失败：\(String(cString: strerror(e)))"
            case .listenFailed(let e): return "listen() 失败：\(String(cString: strerror(e)))"
            case .connectFailed(let e): return "connect() 失败：\(String(cString: strerror(e)))"
            }
        }
    }

    /// 填 `sockaddr_un`。`sun_path` 是定长 C 数组，Swift 里只能逐字节写。
    private static func makeAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= HubSocket.maxPathLength else {
            throw SocketError.pathTooLong(path)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func withAddress<T>(
        _ addr: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// 建监听 socket。会先删掉残留的 socket 文件（上次异常退出留下的）。
    static func listen(at path: String, backlog: Int32 = 16) throws -> Int32 {
        var addr = try makeAddress(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        // 上次进程被 kill -9 时 socket 文件会留下，不删的话 bind 报 EADDRINUSE。
        unlink(path)

        let bound = withAddress(&addr) { Darwin.bind(fd, $0, $1) }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw SocketError.bindFailed(e)
        }

        guard Darwin.listen(fd, backlog) == 0 else {
            let e = errno
            close(fd)
            throw SocketError.listenFailed(e)
        }

        // 只有当前用户能连。这条链路能否决工具执行，不该对其他用户开放。
        chmod(path, 0o600)
        return fd
    }

    /// 连接到监听中的 socket。
    static func connect(to path: String) throws -> Int32 {
        var addr = try makeAddress(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        let connected = withAddress(&addr) { Darwin.connect(fd, $0, $1) }
        guard connected == 0 else {
            let e = errno
            close(fd)
            throw SocketError.connectFailed(e)
        }
        return fd
    }

    /// 读一行（以 `\n` 结尾）。返回 nil 表示对端已关闭。
    ///
    /// - Parameter timeout: 秒。nil 表示一直阻塞。
    static func readLine(fd: Int32, timeout: TimeInterval?) -> String? {
        var buffer = Data()
        var byte: UInt8 = 0
        let deadline = timeout.map { Date().addingTimeInterval($0) }

        while true {
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0, waitReadable(fd: fd, timeout: remaining) else { return nil }
            }

            let n = read(fd, &byte, 1)
            if n == 0 { return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == UInt8(ascii: "\n") {
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(byte)

            // 防御：正常的一行事件是几百字节到几 KB。超过 1 MB 说明对端行为异常，
            // 不能让它把内存吃光。
            if buffer.count > 1_048_576 { return nil }
        }
    }

    /// 写一行。
    @discardableResult
    static func writeLine(fd: Int32, _ line: String) -> Bool {
        var data = Array((line + "\n").utf8)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }

    /// 用 `poll` 等 fd 可读。
    private static func waitReadable(fd: Int32, timeout: TimeInterval) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let millis = Int32(max(0, min(timeout * 1000, Double(Int32.max))))
        let result = poll(&pfd, 1, millis)
        return result > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }
}
