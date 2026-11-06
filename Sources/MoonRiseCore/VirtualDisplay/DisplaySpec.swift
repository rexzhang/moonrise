import Foundation

/// 虚拟显示器规格。像素尺寸是身份推导依据，HiDPI 恒开。
public struct DisplaySpec: Equatable, Codable, Sendable {
    public var name: String
    public var width: Int       // 像素（= maxPixels）
    public var height: Int
    public var refreshRate: Int

    public init(name: String, width: Int, height: Int, refreshRate: Int) {
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
    }

    public static let `default` = DisplaySpec(name: "Moon", width: 2560, height: 1600, refreshRate: 60)

    public static let minDimension = 64
    public static let maxDimension = 16_384
    public static let minRefreshRate = 1
    public static let maxRefreshRate = 240

    public var logicalWidth: Int { width / 2 }
    public var logicalHeight: Int { height / 2 }

    public var identity: DisplayIdentity {
        identity(salt: 0)
    }

    public func identity(salt: UInt32) -> DisplayIdentity {
        DisplayIdentity(
            vendorID: DisplayIdentity.vendorID,
            productID: DisplayIdentity.productID,
            serialNumber: DisplayIdentity.derivedSerial(name: name, width: width, height: height, salt: salt))
    }

    /// 全倍 Retina 需要"逻辑模式"参与 HiDPI 倍化合成；
    /// 尺寸过小（< 64px）时跳过逻辑模式，此时只有 1:1 模式可用。
    public var supportsLogicalMode: Bool {
        logicalWidth >= Self.minDimension && logicalHeight >= Self.minDimension
    }

    /// shim 需要的模式数组：主模式在前（= maxPixels），逻辑模式随后。
    public var modeSpecs: [[NSNumber]] {
        var modes: [[NSNumber]] = [
            [NSNumber(value: width), NSNumber(value: height), NSNumber(value: refreshRate)]
        ]
        if supportsLogicalMode {
            modes.append([
                NSNumber(value: logicalWidth), NSNumber(value: logicalHeight), NSNumber(value: refreshRate)
            ])
        }
        return modes
    }

    public enum ValidationError: LocalizedError {
        case dimensionOutOfRange(String, Int)
        case refreshRateOutOfRange(Int)
        case emptyName

        public var errorDescription: String? {
            switch self {
            case .dimensionOutOfRange(let what, let value):
                return "\(what) \(value) 超出范围 [\(DisplaySpec.minDimension), \(DisplaySpec.maxDimension)]"
            case .refreshRateOutOfRange(let value):
                return "刷新率 \(value) Hz 超出范围 [\(DisplaySpec.minRefreshRate), \(DisplaySpec.maxRefreshRate)]"
            case .emptyName:
                return "显示器名称不能为空"
            }
        }
    }

    public func validated() throws -> DisplaySpec {
        guard width >= Self.minDimension, width <= Self.maxDimension else {
            throw ValidationError.dimensionOutOfRange("宽度", width)
        }
        guard height >= Self.minDimension, height <= Self.maxDimension else {
            throw ValidationError.dimensionOutOfRange("高度", height)
        }
        guard refreshRate >= Self.minRefreshRate, refreshRate <= Self.maxRefreshRate else {
            throw ValidationError.refreshRateOutOfRange(refreshRate)
        }
        guard !name.isEmpty else {
            throw ValidationError.emptyName
        }
        return self
    }
}
