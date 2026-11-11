import Foundation

/// 逐实例日志尾随 → 每屏串流状态（D12）。
/// 标记行（spike 实测）：会话开始 "New streaming session started"，会话结束 "CLIENT DISCONNECTED"。
/// 轮询读取新增字节（默认 1s），解析标记行驱动状态；日志不可达保持原状态，对账兜底由看门狗做。
public final class StreamStateMonitor {
    public var onStreamingChanged: ((UUID, Bool) -> Void)?

    private let lock = NSLock()
    private var streaming: [UUID: Bool] = [:]
    private var tracked: [UUID: URL] = [:]
    private var offsets: [UUID: UInt64] = [:]
    private var carry: [UUID: String] = [:]   // 半行缓冲
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.moonrise.stream-monitor")

    public init() {}

    /// 槽位当前是否串流中（未跟踪返回 false）。
    public func isStreaming(slotID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return streaming[slotID] ?? false
    }

    /// 开始跟踪一个实例日志。从头读：App 重启后能由历史标记推出进行中的会话态。
    public func track(slotID: UUID, logURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        tracked[slotID] = logURL
        offsets[slotID] = 0
        if streaming[slotID] == nil {
            streaming[slotID] = false
        }
    }

    public func untrack(slotID: UUID) {
        lock.lock()
        tracked[slotID] = nil
        offsets[slotID] = nil
        carry[slotID] = nil
        let wasStreaming = streaming.removeValue(forKey: slotID)
        lock.unlock()
        if wasStreaming == true {
            onStreamingChanged?(slotID, false)
        }
    }

    public func start(interval: TimeInterval = 1.0) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.pollNow() }
        source.resume()
        timer = source
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 手动触发一轮（看门狗 30s 对账复用）。
    public func pollNow() {
        let snapshot: [(UUID, URL)]
        lock.lock()
        snapshot = tracked.map { ($0.key, $0.value) }
        lock.unlock()
        for (slotID, url) in snapshot {
            poll(slotID: slotID, url: url)
        }
    }

    private func poll(slotID: UUID, url: URL) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return   // 日志尚未生成/不可达：保持原状态
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        lock.lock()
        let current = offsets[slotID] ?? 0
        lock.unlock()
        guard size >= current else {
            // 日志被重建：重置偏移，下轮从头读
            lock.lock()
            offsets[slotID] = 0
            lock.unlock()
            return
        }
        guard size > current else { return }
        handle.seek(toFileOffset: current)
        guard let data = try? handle.read(upToCount: Int(size - current)), !data.isEmpty else { return }

        lock.lock()
        offsets[slotID] = size
        lock.unlock()
        guard let text = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        let carried = carry[slotID] ?? ""
        var lines = (carried + text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let remainder = lines.isEmpty ? "" : lines.removeLast()
        carry[slotID] = remainder
        var state = streaming[slotID] ?? false
        lock.unlock()

        var changed = false
        for line in lines {
            let newState = Self.apply(line: line, to: state)
            if newState != state {
                state = newState
                changed = true
            }
        }

        if changed {
            lock.lock()
            streaming[slotID] = state
            lock.unlock()
            onStreamingChanged?(slotID, state)
        }
    }

    /// 纯函数：单行标记 → 状态迁移（可测）。
    public static func apply(line: String, to state: Bool) -> Bool {
        if line.contains("New streaming session started") { return true }
        if line.contains("CLIENT DISCONNECTED") { return false }
        return state
    }
}
