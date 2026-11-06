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

        public init(name: String = "Moon", width: Int = 2560, height: Int = 1600, refreshRate: Int = 60) {
            self.name = name
            self.width = width
            self.height = height
            self.refreshRate = refreshRate
        }

        public var spec: DisplaySpec {
            DisplaySpec(name: name, width: width, height: height, refreshRate: refreshRate)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Moon"
            width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 2560
            height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1600
            refreshRate = try c.decodeIfPresent(Int.self, forKey: .refreshRate) ?? 60
        }
    }

    public struct SunshineConfig: Codable, Equatable, Sendable {
        public var autoConfigure: Bool
        public var configPath: String
        public var restartPolicy: RestartPolicy

        public enum RestartPolicy: String, Codable, Sendable {
            /// 由 App 编排：brew services start/stop/restart（回退模式）
            case brewServices
            /// 由 MoonRise 的 LaunchAgent（com.moonrise.sunshine）托管 Sunshine（默认；退出连带停止）
            case managed
            /// 只写配置，不重启（提示手动重启）
            case manual
        }

        /// 启动 Sunshine 时禁用音频串流（sunshine.conf 的 stream_audio），默认开启
        public var disableAudioStreaming: Bool
        /// 隐藏 Sunshine 的菜单栏托盘图标（QT_QPA_PLATFORM=minimal），默认开启
        public var hideTrayIcon: Bool

        public init(autoConfigure: Bool = true, configPath: String = "~/.config/sunshine/sunshine.conf", restartPolicy: RestartPolicy = .managed, disableAudioStreaming: Bool = true, hideTrayIcon: Bool = true) {
            self.autoConfigure = autoConfigure
            self.configPath = configPath
            self.restartPolicy = restartPolicy
            self.disableAudioStreaming = disableAudioStreaming
            self.hideTrayIcon = hideTrayIcon
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            autoConfigure = try c.decodeIfPresent(Bool.self, forKey: .autoConfigure) ?? true
            configPath = try c.decodeIfPresent(String.self, forKey: .configPath) ?? "~/.config/sunshine/sunshine.conf"
            restartPolicy = try c.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy) ?? .managed
            disableAudioStreaming = try c.decodeIfPresent(Bool.self, forKey: .disableAudioStreaming) ?? true
            hideTrayIcon = try c.decodeIfPresent(Bool.self, forKey: .hideTrayIcon) ?? true
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
