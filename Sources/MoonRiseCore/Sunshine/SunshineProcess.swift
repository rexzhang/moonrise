import Foundation

/// Sunshine 安装探测与生命周期编排协议。
/// 实现：ChildProcessSunshineManager（默认托管）/ BrewServicesSunshineManager（回退），
/// App 层无感切换。
public protocol SunshineManaging {
    /// 探测安装；nil = 未安装。
    func detect() -> SunshineInstallInfo?
    func start() throws
    func stop() throws
    func restart() throws
    /// 供菜单展示的单行运行状态。
    func statusLine() -> String
}

public struct SunshineInstallInfo {
    public let binaryPath: String
}

/// brew services 编排实现（默认）。服务标签随 brew 版本变化
/// （实测 macOS 27/brew 当前为 sh.brew.sunshine），故只用 brew 命令本身。
public struct BrewServicesSunshineManager: SunshineManaging {
    public let brewPath: String

    public init(brewPath: String) {
        self.brewPath = brewPath
    }

    public static func detectBrew() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func detectBinary() -> String? {
        let candidates = [
            "/opt/homebrew/opt/sunshine/bin/sunshine",
            "/opt/homebrew/bin/sunshine",
            "/usr/local/opt/sunshine/bin/sunshine",
            "/usr/local/bin/sunshine"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func detect() -> SunshineInstallInfo? {
        guard Self.detectBinary() != nil else { return nil }
        return SunshineInstallInfo(binaryPath: Self.detectBinary()!)
    }

    public func start() throws {
        try runServiceCommand("start")
    }

    public func stop() throws {
        try runServiceCommand("stop")
    }

    public func restart() throws {
        try runServiceCommand("restart")
    }

    public func statusLine() -> String {
        "brew services 托管"
    }

    private func runServiceCommand(_ verb: String) throws {
        guard FileManager.default.fileExists(atPath: brewPath) else {
            throw SunshineManagerError.brewMissing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = ["services", verb, "sunshine"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SunshineManagerError.commandFailed("brew services \(verb) sunshine（退出码 \(process.terminationStatus)）")
        }
    }
}

public enum SunshineManagerError: LocalizedError {
    case brewMissing
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .brewMissing:
            return "找不到 brew（/opt/homebrew/bin/brew）"
        case .commandFailed(let detail):
            return "Sunshine 服务操作失败：\(detail)"
        }
    }
}
