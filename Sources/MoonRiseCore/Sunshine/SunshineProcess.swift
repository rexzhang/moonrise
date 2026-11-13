import Foundation

/// Sunshine 实例生命周期协议。实现：ChildProcessSunshineManager（MoonRise 子进程独占托管）。
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
