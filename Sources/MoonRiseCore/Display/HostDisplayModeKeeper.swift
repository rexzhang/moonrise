import CoreGraphics
import Foundation

/// 记录 MoonRise 启动时的 host 显示模式，在虚拟屏拓扑变化（Moon 建立/销毁）后自动恢复——
/// 避免 macOS 在显示器增减时把内建屏踢出动态 HiDPI 模式（缩放跳变）。
/// 模式引用（CGDisplayMode）对同一显示器持续有效，可直接回设。
public struct HostDisplayModeRecord {
    let displayID: CGDirectDisplayID
    let mode: CGDisplayMode
    let pixelWidth: Int
    let pixelHeight: Int
    let widthPts: Int
    let heightPts: Int
    let refreshRate: Double
}

public enum HostDisplayModeKeeper {
    private static var records: [HostDisplayModeRecord] = []

    /// 快照当前全部活动显示器的模式（host 模式基线）
    public static func snapshot(excluding excluded: CGDirectDisplayID? = nil) {
        records.removeAll()
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        for id in ids where id != excluded {
            guard let mode = CGDisplayCopyDisplayMode(id) else { continue }
            records.append(HostDisplayModeRecord(
                displayID: id, mode: mode,
                pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                widthPts: mode.width, heightPts: mode.height,
                refreshRate: mode.refreshRate))
        }
        print("[HostDisplayModeKeeper] 已快照 \(records.count) 台显示器模式")
    }

    /// 拓扑变化后恢复：当前模式与快照不一致的显示器回设为快照模式
    public static func restoreAll() {
        for record in records {
            let current = CGDisplayCopyDisplayMode(record.displayID)
            let sameMode = current.map {
                $0.pixelWidth == record.pixelWidth && $0.pixelHeight == record.pixelHeight
                    && abs($0.refreshRate - record.refreshRate) < 0.1
            } ?? false
            if sameMode { continue }
            let ok = CGDisplaySetDisplayMode(record.displayID, record.mode, nil) == .success
            print("[HostDisplayModeKeeper] \(ok ? "✓ 恢复" : "❌ 恢复失败") 显示器 \(record.displayID) → px\(record.pixelWidth)x\(record.pixelHeight)@\(record.refreshRate)Hz")
        }
    }
}
