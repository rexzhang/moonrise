import Foundation
import CoreGraphics
import VirtualDisplayObjC

/// 已落地的虚拟显示器。
public struct RealizedDisplay: Sendable {
    public init(displayID: CGDirectDisplayID, spec: DisplaySpec, identity: DisplayIdentity) {
        self.displayID = displayID
        self.spec = spec
        self.identity = identity
    }

    public let displayID: CGDirectDisplayID
    public let spec: DisplaySpec
    public let identity: DisplayIdentity
}

/// 虚拟显示器生命周期：按槽位 realize/teardown（多屏，槽位 UUID = 配置锚）。
/// 铁律：绝不改模式、绝不程序化排列（否则 release 不再销毁）；
/// 改分辨率一律销毁重建；身份不符（记忆了别的模式）时带盐重建。
public final class VirtualDisplayController {
    private let list: DisplayListReading

    /// 创建前必查；抛出即 macOS 已移除私有 API。
    public init(list: DisplayListReading = LiveDisplayList()) throws {
        self.list = list
        if let error = VDVirtualDisplay.apiAvailabilityError() {
            throw error
        }
    }

    /// 建指定槽位的屏（同槽已有则先销毁；其它槽位不受影响）。阻塞（等待激活 ~0.5s）：在后台队列调用。
    @discardableResult
    public func realize(slotID: UUID, spec: DisplaySpec) throws -> RealizedDisplay {
        let validated = try spec.validated()
        try teardown(slotID: slotID)

        if let display = try realizeOnce(slotID: slotID, spec: validated, salt: 0) {
            return display
        }
        // 该身份被 macOS 记忆了错误模式：换带盐身份（无记忆的新显示器）重建
        if let display = try realizeOnce(slotID: slotID, spec: validated, salt: DisplayIdentity.retrySalt) {
            return display
        }
        try teardown(slotID: slotID)
        throw VirtualDisplayControllerError.wrongMode(spec: validated)
    }

    /// 销毁指定槽位的屏（幂等；未持有该槽直接返回）。阻塞（等待消失，实测 0.2–0.4s）。
    public func teardown(slotID: UUID, timeout: TimeInterval = 5) throws {
        let display: VDVirtualDisplay? = lock.withLock { slots[slotID] }
        guard let display else { return }
        lock.withLock { slots[slotID] = nil }
        let id = display.displayID
        display.destroy()
        guard DisplayList.waitGone(id: id, list: list, timeout: timeout) else {
            throw VirtualDisplayControllerError.teardownTimeout(id: id)
        }
    }

    /// 销毁全部槽位（退出用）。单个槽位超时记录后继续，最后抛出首个错误。
    public func teardownAll(timeout: TimeInterval = 5) throws {
        let slotIDs: [UUID] = lock.withLock { Array(slots.keys) }
        var firstError: Error?
        for slotID in slotIDs {
            do {
                try teardown(slotID: slotID, timeout: timeout)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    /// 槽位当前 displayID（未持有返回 nil）。
    public func displayID(of slotID: UUID) -> CGDirectDisplayID? {
        lock.withLock { slots[slotID]?.displayID }
    }

    // MARK: - 私有

    private let lock = NSLock()
    private var slots: [UUID: VDVirtualDisplay] = [:]

    /// 返回 nil 表示该身份落在了错误模式（调用方带盐重试）。
    private func realizeOnce(slotID: UUID, spec: DisplaySpec, salt: UInt32) throws -> RealizedDisplay? {
        let identity = spec.identity(salt: salt)
        let display: VDVirtualDisplay
        do {
            display = try VDVirtualDisplay(
                name: spec.name as String,
                maxPixelsWide: UInt32(spec.width),
                maxPixelsHigh: UInt32(spec.height),
                modes: spec.modeSpecs,
                hiDPI: spec.hiDPI,
                vendorID: identity.vendorID,
                productID: identity.productID,
                serialNumber: identity.serialNumber)
        } catch let error as NSError where error.domain == VDVirtualDisplayErrorDomain {
            throw VirtualDisplayControllerError.shim(error)
        }

        lock.withLock { slots[slotID] = display }
        let displayID = display.displayID

        // 边界可能滞后：短暂轮询，接受 1:1 或逻辑尺寸，其余视为错误模式
        var bounds: CGRect?
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if let b = list.bounds(of: displayID), b.width > 0 {
                bounds = b
                if DisplayList.boundsAcceptable(b, spec: spec) { break }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard let bounds, DisplayList.boundsAcceptable(bounds, spec: spec) else {
            try teardown(slotID: slotID)
            return nil
        }
        return RealizedDisplay(displayID: displayID, spec: spec, identity: identity)
    }
}

public enum VirtualDisplayControllerError: LocalizedError {
    case shim(NSError)
    case wrongMode(spec: DisplaySpec)
    case teardownTimeout(id: CGDirectDisplayID)

    public var errorDescription: String? {
        switch self {
        case .shim(let error):
            return error.localizedDescription
        case .wrongMode(let spec):
            return "虚拟屏身份 \(spec.name) \(spec.width)x\(spec.height) 被系统记忆了错误模式，带盐重建仍失败"
        case .teardownTimeout(let id):
            return "显示器 \(id) 在 5s 内未从活动列表消失"
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
