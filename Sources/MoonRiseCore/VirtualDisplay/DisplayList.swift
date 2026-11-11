import Foundation
import CoreGraphics

/// 显示列表读取抽象（测试可替换为 mock）。
/// 注：创建进程读不到自家虚拟屏的模式缓存，因此状态判断只用
/// CGGetActiveDisplayList + CGDisplayBounds，绝不读模式。
public protocol DisplayListReading {
    func activeDisplayIDs() -> [CGDirectDisplayID]
    func bounds(of id: CGDirectDisplayID) -> CGRect?
}

public struct LiveDisplayList: DisplayListReading {
    public init() {}
    public func activeDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public func bounds(of id: CGDirectDisplayID) -> CGRect? {
        activeDisplayIDs().contains(id) ? CGDisplayBounds(id) : nil
    }
}

public enum DisplayList {
    /// 轮询等待显示器从活动列表消失（销毁是异步的，实测 0.2–0.4s）。
    /// 阻塞调用：在后台队列使用。每轮泵当前线程 run loop + 睡眠防自旋。
    public static func waitGone(
        id: CGDirectDisplayID,
        list: DisplayListReading,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while list.activeDisplayIDs().contains(id) {
            guard Date() < deadline else { return false }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.025, true)
            Thread.sleep(forTimeInterval: 0.025)
        }
        return true
    }

    /// 创建后屏的落点判定：点宽等于像素宽（1:1 初始模式）或逻辑宽
    /// （HiDPI 开启且用户在系统设置选过 Retina 模式并已被身份记忆）都算正常；
    /// HiDPI 关闭时逻辑尺寸视为错误模式；其它说明该身份记忆了错误模式，需要带盐重建。
    public static func boundsAcceptable(_ bounds: CGRect, spec: DisplaySpec) -> Bool {
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        if width == spec.width && height == spec.height {
            return true
        }
        if spec.hiDPI && spec.supportsLogicalMode && width == spec.logicalWidth && height == spec.logicalHeight {
            return true
        }
        return false
    }
}
