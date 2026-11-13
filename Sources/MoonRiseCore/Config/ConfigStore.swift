import Foundation
import Observation

/// 应用设置统一存储：UserDefaults 单键 JSON blob，全部设置修改经 mutate 收口。
/// 首启自动导入旧 config.json（改名归档 .imported），此后 UserDefaults 为唯一持久层。
@Observable
public final class ConfigStore {
    private static let blobKey = "appConfig"

    private let defaults: UserDefaults

    /// 当前设置快照（只读；编排层与页面经此读取）。
    public private(set) var config: AppConfig

    public init(defaults: UserDefaults = .standard, legacyURL: URL = Paths.configURL) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.blobKey),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
            return
        }
        config = Self.importLegacyFile(at: legacyURL, into: defaults) ?? .standard
    }

    /// 唯一写通道：改 → 持久化（@Observable 自动通知观察方）。
    public func mutate(_ change: (inout AppConfig) -> Void) {
        var updated = config
        change(&updated)
        guard updated != config else { return }
        config = updated
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.blobKey)
    }

    /// 旧 config.json → blob 导入 + 归档（同目录 .imported 后缀，不删除）。无旧文件返回 nil。
    private static func importLegacyFile(at url: URL, into defaults: UserDefaults) -> AppConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let config = AppConfig.load(url: url)
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: blobKey)
        }
        let archived = url.deletingPathExtension().appendingPathExtension("json.imported")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: url, to: archived)
        Log.info("旧配置已导入 UserDefaults 并归档：\(archived.path)")
        return config
    }
}
