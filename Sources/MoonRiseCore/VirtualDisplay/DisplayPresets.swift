import Foundation

/// 分辨率预设：按屏幕参数归纳去重（Apple 实测机型 + 通用），每项自带 HiDPI 支持标记。
/// 预设只承载规格；显示名由槽位命名规则生成，不取自预设。
public struct DisplayPreset: Equatable, Sendable, Identifiable {
    public let group: String
    public let name: String
    public let width: Int
    public let height: Int
    public let refreshRate: Int
    public let hiDPI: Bool

    public var id: String { "\(group)|\(name)" }

    public init(group: String, name: String, width: Int, height: Int, refreshRate: Int = 60, hiDPI: Bool) {
        self.group = group
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
    }
}

public enum DisplayPresets {
    /// MacBook 内置 Retina 屏
    public static let macbook: [DisplayPreset] = [
        DisplayPreset(group: "MacBook", name: "MacBook 13″（Air/Pro）", width: 2560, height: 1600, hiDPI: true),
        DisplayPreset(group: "MacBook", name: "MacBook Air 13″", width: 2560, height: 1664, hiDPI: true),
        DisplayPreset(group: "MacBook", name: "MacBook Air 15″", width: 2880, height: 1864, hiDPI: true),
        DisplayPreset(group: "MacBook", name: "MacBook Pro 14″", width: 3024, height: 1964, hiDPI: true),
        DisplayPreset(group: "MacBook", name: "MacBook Pro 16″", width: 3456, height: 2234, hiDPI: true),
    ]

    /// iPad 内置 Retina 屏
    public static let ipad: [DisplayPreset] = [
        DisplayPreset(group: "iPad", name: "iPad mini 4/5（7.9″）", width: 2048, height: 1536, hiDPI: true),
        DisplayPreset(group: "iPad", name: "iPad 10.2″（第 7–9 代）", width: 2160, height: 1620, hiDPI: true),
        DisplayPreset(group: "iPad", name: "iPad mini 6/7（8.3″）", width: 2266, height: 1488, hiDPI: true),
        DisplayPreset(group: "iPad", name: "iPad Air / 10.9″", width: 2360, height: 1640, hiDPI: true),
        DisplayPreset(group: "iPad", name: "iPad Pro 11″", width: 2388, height: 1668, hiDPI: true),
        DisplayPreset(group: "iPad", name: "iPad Pro 12.9″/13″", width: 2732, height: 2048, hiDPI: true),
    ]

    /// Apple 外接显示器
    public static let appleDisplay: [DisplayPreset] = [
        DisplayPreset(group: "Apple 显示器", name: "iMac 24″（4.5K）", width: 4480, height: 2520, hiDPI: true),
        DisplayPreset(group: "Apple 显示器", name: "Studio Display / 5K", width: 5120, height: 2880, hiDPI: true),
        DisplayPreset(group: "Apple 显示器", name: "Pro Display XDR（6K）", width: 6016, height: 3384, hiDPI: true),
    ]

    /// 通用规格（默认非 Retina 面板习惯）
    public static let general: [DisplayPreset] = [
        DisplayPreset(group: "通用", name: "1920×1080（FHD）", width: 1920, height: 1080, hiDPI: false),
        DisplayPreset(group: "通用", name: "2560×1440（1440p）", width: 2560, height: 1440, hiDPI: false),
        DisplayPreset(group: "通用", name: "1920×1200（16:10）", width: 1920, height: 1200, hiDPI: false),
        DisplayPreset(group: "通用", name: "3840×2160（4K UHD）", width: 3840, height: 2160, hiDPI: true),
    ]

    public static var all: [DisplayPreset] { macbook + ipad + appleDisplay + general }
}
