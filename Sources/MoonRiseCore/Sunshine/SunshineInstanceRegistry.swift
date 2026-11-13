import Foundation

/// 多实例编排：第 2..N 屏各持独立实例管理器（D1/D13）；首屏走主 conf，不经注册表。
/// 实例的启动/重启必须串行化（spike S7：并发探测互卡）——顺序由编排层负责，注册表只管生命周期与查找。
public final class SunshineInstanceRegistry {
    private let lock = NSLock()
    private var instances: [UUID: ChildProcessSunshineManager] = [:]
    private let sourceBinaryPath: String

    public init(sourceBinaryPath: String) {
        self.sourceBinaryPath = sourceBinaryPath
    }

    /// 取/建指定槽位的实例管理器（懒建：先落实二进制副本，D16）。
    /// 建实例需在后台队列调用（复制 bundle + 哈希校验）。
    public func manager(for display: DisplayConfig) throws -> ChildProcessSunshineManager {
        lock.lock()
        defer { lock.unlock() }
        if let existing = instances[display.id] {
            return existing
        }
        try InstanceConf.ensureStateFile(for: display.id)   // 先于首次启动：防 FRESH_STATE
        let binary = try InstanceConf.ensureBinaryCopy(sourceBinaryPath: sourceBinaryPath, slotID: display.id)
        let manager = ChildProcessSunshineManager(
            binPath: binary.path,
            confPath: InstanceConf.confURL(for: display.id).path,
            logURL: InstanceConf.logURL(for: display.id),
            label: display.name)
        instances[display.id] = manager
        return manager
    }

    public func managerIfExists(for slotID: UUID) -> ChildProcessSunshineManager? {
        lock.lock()
        defer { lock.unlock() }
        return instances[slotID]
    }

    /// 遗忘实例（调用方先 stop）。删除屏时随后清理实例目录。
    public func forget(slotID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        instances[slotID] = nil
    }

    /// 全部实例状态行（诊断用）。
    public func statusLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return instances.values.map { "\($0.label)：\($0.statusLine())" }
    }
}
