import Darwin
import Foundation

/// 通过 libproc/Sysctl 读取进程信息并发送信号。
///
/// 为什么不继续用 `ps` + `NSRunningApplication`：
/// * `ps -o comm=` 取自内核 `p_comm`，只有 `MAXCOMLEN`(16) 字节，长路径会被截断；
/// * `NSRunningApplication(processIdentifier:)` 对**非 GUI 进程**（java、各种 Helper、
///   守护进程）返回 nil，而进程榜里绝大部分正是这类进程，导致「终止/强制退出」
///   在守卫处就提前返回，按钮点了没有任何效果。
public enum ProcessInspector {
    /// 完整可执行路径；进程不存在或无权限时返回 nil。
    public static func executablePath(of pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE 是 C 宏（4 * MAXPATHLEN），Swift 无法导入，这里展开。
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        // 按返回长度截断，避免依赖 NUL 终止（String(cString:) 已弃用）。
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 启动时间（epoch 秒）。用于在终止前确认 PID 没有被复用。
    public static func startEpoch(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        // sysctl 成功但进程不存在时，kp_proc.p_pid 为 0
        guard info.kp_proc.p_pid == pid else { return nil }
        return String(Int64(info.kp_proc.p_starttime.tv_sec))
    }

    /// 当前 pid 上进程的完整身份；进程不存在时返回 nil。
    public static func identity(of pid: Int32) -> (path: String, start: String)? {
        guard let path = executablePath(of: pid), let start = startEpoch(of: pid) else { return nil }
        return (path, start)
    }

    /// 校验 pid 上的进程仍是目标进程（完整路径 + 启动时间都一致）。
    public static func stillRunning(_ target: ProcessReading) -> Bool {
        guard let live = identity(of: target.pid) else { return false }
        return ProcessIdentity.matches(
            expectedPath: target.executablePath,
            expectedStart: target.startTime,
            observedPath: live.path,
            observedStart: live.start
        )
    }

    /// 发送信号。返回是否成功；失败原因见 `signalErrorDescription`。
    /// 发送信号。成功返回 nil，失败返回 errno（由调用方按当前语言组装提示）。
    /// 用返回值而不是静态可变状态传递错误，避免 Swift 6 的并发隔离问题，
    /// 也顺带消除了多线程下读到别人 errno 的窗口。
    public static func send(_ pid: Int32, _ sig: Int32) -> Int32? {
        kill(pid, sig) == 0 ? nil : errno
    }

    /// 兼容旧的布尔式调用。
    @discardableResult
    public static func signal(_ pid: Int32, _ sig: Int32) -> Bool {
        send(pid, sig) == nil
    }

    /// 把 errno 翻译成面向用户的说明（跟随当前界面语言）。
    public static func errorDescription(_ code: Int32) -> String {
        switch code {
        case EPERM: return Strings.current(.permissionDenied)
        case ESRCH: return Strings.current(.processAlreadyExited)
        case EINVAL: return Strings.current(.invalidSignal)
        default: return Strings.current(.signalFailed, Int(code))
        }
    }
}
