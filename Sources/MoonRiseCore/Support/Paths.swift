import Foundation

/// 全部文件路径与 ~ 展开。
public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    public static var configURL: URL {
        home.appendingPathComponent(".config/moonrise/config.json")
    }

    public static var stateDirectory: URL {
        home.appendingPathComponent(".local/state/moonrise")
    }

    public static var stateURL: URL {
        stateDirectory.appendingPathComponent("state.json")
    }

    /// 扩展屏实例根目录：~/.config/moonrise/sunshine-instances/
    public static var sunshineInstancesDirectory: URL {
        home.appendingPathComponent(".config/moonrise/sunshine-instances")
    }

    /// 受管 Sunshine 根目录：~/.config/moonrise/sunshine/
    public static var managedSunshineDirectory: URL {
        home.appendingPathComponent(".config/moonrise/sunshine")
    }

    /// 受管 Sunshine bundle（官方 release 整 bundle 副本，主实例运行源）
    public static var managedSunshineBundleURL: URL {
        managedSunshineDirectory.appendingPathComponent("Sunshine.app")
    }

    /// 受管 Sunshine 内层可执行
    public static var managedSunshineExecutableURL: URL {
        managedSunshineBundleURL.appendingPathComponent("Contents/MacOS/sunshine")
    }

    /// 受管 Sunshine 换装工作区：sunshine/staging/
    public static var managedSunshineStagingDirectory: URL {
        managedSunshineDirectory.appendingPathComponent("staging")
    }

    /// 单个实例目录：sunshine-instances/<槽位UUID>/（conf + bin/ + credentials/）
    public static func instanceDirectory(for slotID: UUID) -> URL {
        sunshineInstancesDirectory.appendingPathComponent(slotID.uuidString)
    }

    /// 实例日志：~/.local/state/moonrise/sunshine-<槽位UUID前8位>.log
    public static func instanceLogURL(for slotID: UUID) -> URL {
        stateDirectory.appendingPathComponent("sunshine-\(slotID.uuidString.prefix(8)).log")
    }

    /// 展开 ~ 前缀（配置里允许写 "~/..." 形式）。
    public static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" || path.hasPrefix("~/") {
            return home.path + path.dropFirst()
        }
        return path
    }

    public static func ensureParentDirectory(of url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
