import Foundation

/// 单屏槽位：槽位 UUID 是持久锚（实例目录/端口/运行态映射挂在 id 上）。
public struct DisplayConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// 持久编号（1 起，删屏留洞不重排）
    public var slotNumber: Int
    /// 显示名创建时冻结（自动命名 Moon N；改名 = 身份变化，走重建流程）
    public var name: String
    public var width: Int
    public var height: Int
    public var refreshRate: Int
    public var hiDPI: Bool
    /// 启用开关（停用 = 屏与实例不在运行，配置槽位保留；状态持久化）
    public var enabled: Bool
    /// 实例 base port；首屏 nil = 主 conf 默认端口。分配后冻结
    public var sunshinePort: Int?

    public init(
        id: UUID = UUID(),
        slotNumber: Int,
        name: String,
        width: Int,
        height: Int,
        refreshRate: Int,
        hiDPI: Bool = true,
        enabled: Bool = true,
        sunshinePort: Int? = nil
    ) {
        self.id = id
        self.slotNumber = slotNumber
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.enabled = enabled
        self.sunshinePort = sunshinePort
    }

    public var spec: DisplaySpec {
        DisplaySpec(name: name, width: width, height: height, refreshRate: refreshRate, hiDPI: hiDPI)
    }

    private enum CodingKeys: String, CodingKey {
        case id, slotNumber, name, width, height, refreshRate, hiDPI, enabled, sunshinePort
    }

    // 缺键回退默认（向前兼容）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        slotNumber = try c.decodeIfPresent(Int.self, forKey: .slotNumber) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Moon 1"
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 2560
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1600
        refreshRate = try c.decodeIfPresent(Int.self, forKey: .refreshRate) ?? 60
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sunshinePort = try c.decodeIfPresent(Int.self, forKey: .sunshinePort)
    }
}

/// 应用配置。缺字段回退默认值，向前兼容。
public struct AppConfig: Codable, Equatable, Sendable {
    public var displays: [DisplayConfig]
    /// 虚拟屏建立/销毁后自动恢复 host 显示器的缩放基线（全局开关，默认开启）
    public var keepHostScaling: Bool
    public var sunshine: SunshineConfig

    public struct SunshineConfig: Codable, Equatable, Sendable {
        public var autoConfigure: Bool
        public var configPath: String
        public var restartPolicy: RestartPolicy

        public enum RestartPolicy: String, Codable, Sendable {
            /// 由 App 编排：brew services start/stop/restart（回退模式）
            case brewServices
            /// 由 MoonRise 以子进程独占托管 Sunshine（默认；退出连带停止）
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

    public init(displays: [DisplayConfig]? = nil, keepHostScaling: Bool = true, sunshine: SunshineConfig = .init()) {
        self.displays = displays ?? [DisplayConfig(slotNumber: 1, name: "Moon 1", width: 2560, height: 1600, refreshRate: 60)]
        self.keepHostScaling = keepHostScaling
        self.sunshine = sunshine
    }

    /// 首个已启用屏（单屏路径使用；多屏编排见 DisplayReconcilePlan）
    public var primaryDisplay: DisplayConfig? {
        displays.first { $0.enabled } ?? displays.first
    }

    // MARK: - 迁移读取（旧单屏 display 键 → displays 数组，D8）

    private enum CodingKeys: String, CodingKey {
        case displays, keepHostScaling, sunshine, display
    }

    private struct LegacyDisplay: Decodable {
        let width: Int
        let height: Int
        let refreshRate: Int
        let keepHostScaling: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 2560
            height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1600
            refreshRate = try c.decodeIfPresent(Int.self, forKey: .refreshRate) ?? 60
            keepHostScaling = try c.decodeIfPresent(Bool.self, forKey: .keepHostScaling) ?? true
        }

        private enum CodingKeys: String, CodingKey {
            case width, height, refreshRate, keepHostScaling
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try? c.decodeIfPresent(LegacyDisplay.self, forKey: .display)
        if let displays = try? c.decodeIfPresent([DisplayConfig].self, forKey: .displays), !displays.isEmpty {
            self.displays = displays
        } else if let legacy {
            // 旧单屏配置迁为首元素：尺寸保留，显示名统一 Moon 1（该屏记忆一次性重置，D8）
            self.displays = [DisplayConfig(slotNumber: 1, name: "Moon 1", width: legacy.width, height: legacy.height, refreshRate: legacy.refreshRate)]
        } else {
            self.displays = [DisplayConfig(slotNumber: 1, name: "Moon 1", width: 2560, height: 1600, refreshRate: 60)]
        }
        keepHostScaling = try c.decodeIfPresent(Bool.self, forKey: .keepHostScaling) ?? legacy?.keepHostScaling ?? true
        sunshine = try c.decodeIfPresent(SunshineConfig.self, forKey: .sunshine) ?? SunshineConfig()
    }

    // 旧 display 键只在读取时识别，不再写出（迁移单向）
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displays, forKey: .displays)
        try c.encode(keepHostScaling, forKey: .keepHostScaling)
        try c.encode(sunshine, forKey: .sunshine)
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
