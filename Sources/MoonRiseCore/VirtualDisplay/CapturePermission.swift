import Foundation
import CoreGraphics
import ApplicationServices

/// MoonRise 自身的 TCC 权限状态（屏幕捕获 + 输入控制）。
/// Sunshine 以子进程运行，macOS 按责任进程向 MoonRise 收权限；
/// 子进程触发的 TCC 检查不会把 MoonRise 写入系统设置列表——
/// 条目注册必须由 MoonRise 本进程调用官方请求 API 完成。
public enum CapturePermission {
    /// 屏幕捕获：已授予则为 true（不弹窗）
    public static var granted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 屏幕捕获：未授予时触发系统授权弹窗并注册条目。非阻塞。
    public static func request() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// 输入控制（设备控制和数据访问面板）：已授予则为 true（不跳转）
    public static var inputControlGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 输入控制：未授予时跳转系统设置并注册条目。
    public static func requestInputControl() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
