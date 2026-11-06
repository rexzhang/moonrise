import Foundation

/// FNV-1a 32 位哈希（与参考实现 go-macos/virtualdisplay 的 defaultSerial 一致）
public enum Fnv1a {
    public static func hash32(_ string: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

/// 虚拟显示器的稳定身份：macOS 按 (vendor, product, serial) 记忆模式与排列，
/// 三元组跨重启稳定，用户拖放的位置与选择的模式才能被记住。
public struct DisplayIdentity: Equatable, Sendable {
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32

    public static let vendorID: UInt32 = 0x6D6F      // "mo"
    public static let productID: UInt32 = 0x6F6E     // "on"（与 vendor 连读 = "moon"）
    /// 记忆模式不符时的重试盐（参考实现同款）
    public static let retrySalt: UInt32 = 0x9E37_79B9

    public init(vendorID: UInt32, productID: UInt32, serialNumber: UInt32) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }

    public static func derivedSerial(name: String, width: Int, height: Int, salt: UInt32) -> UInt32 {
        let hash = Fnv1a.hash32("\(name)|\(width)x\(height)|\(salt)")
        return hash == 0 ? 1 : hash  // 0 读作"未设置"，归一为 1
    }
}
