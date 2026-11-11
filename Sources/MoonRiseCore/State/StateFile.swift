import Foundation
import CoreGraphics

/// 每屏串流状态（D12）。
public enum ScreenState: String, Sendable {
    case streaming
    case idle
    case disabled
    case offline

    /// 菜单状态行符号（图标维持正常/异常两态，不随串流变化）
    public var symbol: String {
        switch self {
        case .streaming: return "●"
        case .idle, .disabled: return "○"
        case .offline: return "▲"
        }
    }

    public var label: String {
        switch self {
        case .streaming: return "串流中"
        case .idle: return "空闲"
        case .disabled: return "未启用"
        case .offline: return "离线"
        }
    }

    /// 判定：停用优先；串流中次之；屏或实例异常为离线；否则空闲。
    public static func resolve(enabled: Bool, displayID: CGDirectDisplayID?, instanceRunning: Bool, streaming: Bool) -> ScreenState {
        guard enabled else { return .disabled }
        if streaming { return .streaming }
        if displayID == nil || !instanceRunning { return .offline }
        return .idle
    }
}

/// 单屏运行态（诊断落盘，只写不读）。
public struct ScreenRuntimeState: Codable, Sendable {
    public var slotID: UUID
    public var name: String
    public var slotNumber: Int
    public var displayID: CGDirectDisplayID?
    public var width: Int
    public var height: Int
    public var refreshRate: Int
    public var hiDPI: Bool
    public var enabled: Bool
    public var streaming: Bool
    public var sunshinePort: Int?
    public var syncStatus: String?

    public init(
        slotID: UUID,
        name: String,
        slotNumber: Int,
        displayID: CGDirectDisplayID?,
        width: Int,
        height: Int,
        refreshRate: Int,
        hiDPI: Bool,
        enabled: Bool,
        streaming: Bool,
        sunshinePort: Int?,
        syncStatus: String? = nil
    ) {
        self.slotID = slotID
        self.name = name
        self.slotNumber = slotNumber
        self.displayID = displayID
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.enabled = enabled
        self.streaming = streaming
        self.sunshinePort = sunshinePort
        self.syncStatus = syncStatus
    }
}

/// 运行状态落盘（诊断窗口与菜单状态摘要的数据源，只写不读）。
public struct AppState: Codable, Sendable {
    public var screens: [ScreenRuntimeState]
    public var lastError: String?
    public var updatedAt: Date

    public init(
        screens: [ScreenRuntimeState] = [],
        lastError: String? = nil
    ) {
        self.screens = screens
        self.lastError = lastError
        self.updatedAt = Date()
    }

    public static func read(from url: URL = Paths.stateURL) -> AppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppState.self, from: data)
    }

    public func write(to url: URL = Paths.stateURL) {
        do {
            try Paths.ensureParentDirectory(of: url)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            Log.error("状态写入失败：\(error.localizedDescription)")
        }
    }
}
