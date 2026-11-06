import Foundation

/// 应用配置（App 与未来扩展共用）。缺字段回退默认值，向前兼容。
public struct AppConfig: Codable, Equatable, Sendable {
    public var display: DisplayConfig
    public var sunshine: SunshineConfig

    public struct DisplayConfig: Codable, Equatable, Sendable {
        public var name: String
        public var width: Int
        public var height: Int
        public var refreshRate: Int

        public init(name: String = "Sunshine Ext", width: Int = 2560, height: Int = 1600, refreshRate: Int = 60) {
            self.name = name
            self.width = width
            self.height = height
            self.refreshRate = refreshRate
        }

        public var spec: DisplaySpec {
            DisplaySpec(name: name, width: width, height: height, refreshRate: refreshRate)
        }
    }

    public struct SunshineConfig: Codable, Equatable, Sendable {
        public var autoConfigure: Bool
        public var configPath: String
        public var restartPolicy: RestartPolicy

        public enum RestartPolicy: String, Codable, Sendable {
            /// 由 App 编排：brew services start/stop/restart（M3 默认）
            case brewServices
            /// 由 App 直接以子进程运行 Sunshine（M4 引入；退出连带停止）
            case childProcess
            /// 只写配置，不重启（提示手动重启）
            case manual
        }

        public init(autoConfigure: Bool = true, configPath: String = "~/.config/sunshine/sunshine.conf", restartPolicy: RestartPolicy = .brewServices) {
            self.autoConfigure = autoConfigure
            self.configPath = configPath
            self.restartPolicy = restartPolicy
        }
    }

    public init(display: DisplayConfig = .init(), sunshine: SunshineConfig = .init()) {
        self.display = display
        self.sunshine = sunshine
    }

    // MARK: - 存取（原子写、缺键回退默认）

    public static func load(url: URL = Paths.configURL) -> AppConfig {
        guard let data = try? Data(contentsOf: url) else {
            return standard
        }
        guard let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            Log.error("配置解析失败，使用默认配置：\(url.path)")
            return standard
        }
        return config
    }

    public static let standard = AppConfig()

    public func save(url: URL = Paths.configURL) throws {
        try Paths.ensureParentDirectory(of: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
