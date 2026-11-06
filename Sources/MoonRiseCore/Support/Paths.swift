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
