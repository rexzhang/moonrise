import Foundation
import CoreGraphics

/// 运行状态落盘（诊断窗口与菜单状态摘要的数据源）。
public struct AppState: Codable, Sendable {
    public var displayID: CGDirectDisplayID?
    public var spec: DisplaySpec?
    public var sunshineOutputName: String?
    public var sunshineSyncStatus: String?
    public var lastError: String?
    public var updatedAt: Date

    public init(
        displayID: CGDirectDisplayID? = nil,
        spec: DisplaySpec? = nil,
        sunshineOutputName: String? = nil,
        sunshineSyncStatus: String? = nil,
        lastError: String? = nil
    ) {
        self.displayID = displayID
        self.spec = spec
        self.sunshineOutputName = sunshineOutputName
        self.sunshineSyncStatus = sunshineSyncStatus
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
