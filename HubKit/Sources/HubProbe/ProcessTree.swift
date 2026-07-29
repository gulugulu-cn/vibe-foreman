import Darwin
import Foundation

/// 一次 `sysctl` 拿到的全系统进程父子关系快照。
///
/// 为什么不 fork `ps`：
/// 1. `ps -o lstart` 的输出是 locale 相关的（本机是中文 locale，会输出中文月份），解析必炸；
/// 2. 一次 sysctl 是单次 syscall，比起 fork + exec + 管道读取快两个数量级；
///    跳转时要对每个 iTerm tab 走一次祖先链，快很重要。
public struct ProcessTree: Sendable {
    /// pid → ppid
    public let parents: [pid_t: pid_t]

    public init(parents: [pid_t: pid_t]) {
        self.parents = parents
    }

    /// 采集当前全系统进程表。失败（极罕见）时返回空树，调用方会自然降级。
    public static func snapshot() -> ProcessTree {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0

        // 第一次调用只问需要多大缓冲区。
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return ProcessTree(parents: [:])
        }

        // 进程表在两次调用之间可能变大，多留 25% 余量，减少 ENOMEM 重试。
        var capacity = size + size / 4
        var buffer = [UInt8](repeating: 0, count: capacity)

        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            var len = capacity
            let result = sysctl(&mib, u_int(mib.count), raw.baseAddress, &len, nil, 0)
            capacity = len
            return result == 0
        }
        guard ok else { return ProcessTree(parents: [:]) }

        let stride = MemoryLayout<kinfo_proc>.stride
        let count = capacity / stride
        guard count > 0 else { return ProcessTree(parents: [:]) }

        var parents = [pid_t: pid_t](minimumCapacity: count)
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                // kinfo_proc 有对齐要求，buffer 是 [UInt8]，必须 loadUnaligned。
                let proc = base.loadUnaligned(fromByteOffset: i * stride, as: kinfo_proc.self)
                let pid = proc.kp_proc.p_pid
                guard pid > 0 else { continue }
                parents[pid] = proc.kp_eproc.e_ppid
            }
        }
        return ProcessTree(parents: parents)
    }

    /// 从 `pid` 出发向上遍历祖先链（含自身），最多 `limit` 层。
    ///
    /// `limit` 是防环保险：正常进程树不会超过十几层，出现环意味着快照撕裂
    /// （采集期间进程表在变），此时宁可截断也不能死循环。
    public func ancestry(of pid: pid_t, limit: Int = 32) -> [pid_t] {
        var chain: [pid_t] = []
        var seen = Set<pid_t>()
        var current = pid

        while current > 0, chain.count < limit, seen.insert(current).inserted {
            chain.append(current)
            guard let parent = parents[current], parent != current else { break }
            current = parent
        }
        return chain
    }

    /// 沿祖先链找到第一个满足条件的 PID。
    ///
    /// 这是「iTerm tab → Claude 会话」绑定的核心：传入 iTerm 报的 `jobPid`，
    /// 谓词是「该 PID 有对应的 sessions/<PID>.json」，命中的就是这个 tab 里跑的会话。
    public func firstAncestor(of pid: pid_t, where predicate: (pid_t) -> Bool) -> pid_t? {
        ancestry(of: pid).first(where: predicate)
    }

    /// 进程是否存活。
    ///
    /// `~/.claude/sessions/` 里死进程的 json 会残留（实测有几天前的），
    /// 不过滤就会在岛上显示一堆幽灵会话。
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0) 不发信号，只做存在性 + 权限检查。
        // EPERM 表示进程存在但不属于我们 —— 对判活而言依然是「存在」。
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
