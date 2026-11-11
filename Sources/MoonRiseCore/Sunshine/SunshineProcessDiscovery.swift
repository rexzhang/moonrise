import Foundation

/// 判定“外部 Sunshine 实例”：pgrep 候选排除 MoonRise 全家族（D9/R3）。
/// 注意：扩展屏实例使用独立二进制副本路径（D16），同路径副本属正常形态——
/// 家族判定按进程归属（托管子进程集合 + 直系 ppid 双保险），绝不按路径。
public enum SunshineProcessDiscovery {
    /// 纯函数：从候选 PID 中筛出外部实例（排除自身、已托管子进程、自身直接子进程）。
    public static func foreignPIDs(
        candidates: [pid_t],
        managedChildren: Set<pid_t>,
        selfPID: pid_t,
        parentOf: (pid_t) -> pid_t?
    ) -> [pid_t] {
        candidates.filter { pid in
            pid != selfPID
                && !managedChildren.contains(pid)
                && parentOf(pid) != selfPID
        }
    }

    /// pgrep 找出全部命令行含 sunshine 的进程（含我们的子进程与外部实例）
    public static func findCandidates() -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "sunshine"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) } ?? []
    }

    /// 进程父 PID（读取失败返回 nil）
    public static func parentPID(of pid: pid_t) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pid_t(text)
    }

    /// SIGTERM 宽限 → SIGKILL 兜底
    public static func terminate(pid: pid_t, graceSeconds: TimeInterval) {
        guard kill(pid, SIGTERM) == 0 else { return }
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }  // 已退出
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(pid, SIGKILL)
    }
}

/// MoonRise 进程级“家族”：自身 + 全部托管子进程 PID（跨实例共享，供外部实例判定）。
public final class ManagedProcessFamily {
    public static let shared = ManagedProcessFamily()

    private let lock = NSLock()
    private var children: Set<pid_t> = []

    /// 测试可用（生产代码统一走 shared）
    public init() {}

    public func add(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        children.insert(pid)
    }

    public func remove(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        children.remove(pid)
    }

    public var managedChildren: Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return children
    }

    /// 外部实例 = sunshine 候选 − 家族
    public func foreign(from candidates: [pid_t], parentOf: (pid_t) -> pid_t? = SunshineProcessDiscovery.parentPID) -> [pid_t] {
        SunshineProcessDiscovery.foreignPIDs(
            candidates: candidates,
            managedChildren: managedChildren,
            selfPID: ProcessInfo.processInfo.processIdentifier,
            parentOf: parentOf)
    }
}
