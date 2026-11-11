// DiagnosticsWindow.swift — 诊断窗口：一键检查整条链路的各项前置条件（逐屏）。

import AppKit
import MoonRiseCore
import VirtualDisplayObjC

final class DiagnosticsWindow: NSWindow, NSWindowDelegate {
    private let textView = NSTextView()
    private var checks: [(String, String)] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        title = "诊断"
        delegate = self
        isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        scrollView.documentView = textView
        contentView = scrollView
        center()
    }

    func present(context: DiagnosticsContext) {
        checks = Self.runChecks(context: context)
        textView.string = checks.map { "\($0.0)\n    \($0.1)" }.joined(separator: "\n\n")
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    struct ScreenDiagnostics {
        let name: String
        let slotID: UUID
        let displayID: CGDirectDisplayID?
        let isLive: Bool
        let spec: DisplaySpec
        let port: Int?
        let enabled: Bool
        let syncStatus: String
    }

    struct DiagnosticsContext {
        let screens: [ScreenDiagnostics]
        let sunshineStatus: String
        let manager: SunshineManaging
    }

    static func runChecks(context: DiagnosticsContext) -> [(String, String)] {
        var results: [(String, String)] = []

        // 1. 私有 API
        if let error = VDVirtualDisplay.apiAvailabilityError() {
            results.append(("❌ 虚拟屏私有 API", error.localizedDescription))
        } else {
            results.append(("✅ 虚拟屏私有 API", "macOS 私有类与 selector 全部在位"))
        }

        // 2. 虚拟屏（逐屏）
        let enabledScreens = context.screens.filter(\.enabled)
        if enabledScreens.isEmpty {
            results.append(("❌ 虚拟屏", "无已启用屏幕"))
        }
        for screen in enabledScreens {
            let spec = screen.spec
            if let displayID = screen.displayID, screen.isLive {
                results.append((
                    "✅ 虚拟屏 · \(screen.name)",
                    "id=\(displayID) \(spec.width)x\(spec.height)@\(spec.refreshRate)（在活动列表中）"
                ))
            } else if screen.displayID != nil {
                results.append(("⚠️ 虚拟屏 · \(screen.name)", "id=\(screen.displayID!) 已不在活动列表（看门狗应会自动重建）"))
            } else {
                results.append(("❌ 虚拟屏 · \(screen.name)", "未创建"))
            }
        }

        // 3. Sunshine 安装
        if let install = context.manager.detect() {
            results.append(("✅ Sunshine 安装", install.binaryPath))
        } else {
            results.append(("❌ Sunshine 未安装", "brew tap lizardbyte/homebrew && brew install lizardbyte/homebrew/sunshine"))
        }

        // 4. output_name 逐屏一致性：首屏主 conf；扩展屏实例 conf
        let mainConfPath = Paths.expandTilde("~/.config/sunshine/sunshine.conf")
        for screen in enabledScreens {
            let expected = screen.displayID.map { String($0) }
            let confPath: String
            if screen.port == nil {
                confPath = mainConfPath
            } else {
                confPath = InstanceConf.confURL(for: screen.slotID).path
            }
            if FileManager.default.fileExists(atPath: confPath) {
                let text = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
                let configured = ConfFile.readValue(in: text, key: "output_name")
                if configured == expected, let expected {
                    results.append(("✅ output_name · \(screen.name)", "\(confPath) → \(expected)"))
                } else {
                    results.append((
                        "⚠️ output_name 不一致 · \(screen.name)",
                        "配置=\(configured ?? "（无）") 期望=\(expected ?? "（无屏）")；菜单 → Sunshine → 重新同步"
                    ))
                }
            } else {
                let hint = screen.port == nil ? "（先启动一次 Sunshine）" : "（实例 conf 由 MoonRise 代建，重新同步即可）"
                results.append(("⚠️ conf 不存在 · \(screen.name)", confPath + hint))
            }
        }

        // 5a. MoonRise 屏幕捕获权限（本进程 preflight，权威；多实例 TCC 同归属）
        let granted = CapturePermission.granted
        results.append((
            granted ? "✅ MoonRise 屏幕捕获权限" : "❌ MoonRise 屏幕捕获权限",
            granted ? "已授予（全部实例共用该归属）" : "未授予——启动时的系统弹窗允许，或系统设置打开 MoonRise 开关"
        ))

        // 5b. Sunshine 捕获权限（从主实例日志推断；扩展屏实例日志各自独立）
        let logResult = checkSunshinePermission(logPath: Paths.expandTilde("~/.config/sunshine/sunshine.log"))
        results.append(logResult)

        // 6. Retina 指引（逐屏，最多 3 条）
        for screen in enabledScreens.prefix(3) {
            let spec = screen.spec
            let hiDPINote = spec.hiDPI
                ? "分辨率选 \(spec.logicalWidth)×\(spec.logicalHeight)（“看起来像”）"
                : "分辨率选 \(spec.width)×\(spec.height)（HiDPI 已关闭）"
            results.append((
                "ℹ️ Retina 指引 · \(screen.name)",
                "系统设置 → 显示器 选中 \(spec.name)，\(hiDPINote)；Moon 端 Moonlight 设 \(spec.width)×\(spec.height)@\(spec.refreshRate) H.264 全屏"
            ))
        }

        // 7. 外接显示器清单（便于发现 Duet 等虚拟屏干扰）
        let liveIDs = context.screens.compactMap { $0.isLive ? $0.displayID : nil }
        let externals = Self.externalDisplaySummary(liveIDs: liveIDs)
        if externals.isEmpty {
            results.append(("✅ 无其他外接显示器", ""))
        } else {
            results.append(("ℹ️ 外接显示器清单", externals.joined(separator: "、") + "（如含 Duet 等虚拟屏且不再使用，建议禁用以免混淆）"))
        }

        return results
    }

    /// 除 moonrise 屏与内建屏之外的全部显示器（vendor=hex 尺寸）
    static func externalDisplaySummary(liveIDs: [CGDirectDisplayID]) -> [String] {
        var out: [String] = []
        for id in liveIDs {
            if CGDisplayVendorNumber(id) == DisplayIdentity.vendorID { continue }
            if CGDisplayIsBuiltin(id) != 0 { continue }
            let bounds = CGDisplayBounds(id)
            out.append("id=\(id) vendor=0x\(String(CGDisplayVendorNumber(id), radix: 16)) \(Int(bounds.width))x\(Int(bounds.height))")
        }
        return out
    }

    /// 最近一次启动的编码器探测是否通过（权限已生效的事实检验）
    static func sunshineProbeGranted(logPath: String) -> Bool {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return false
        }
        let latest = content.components(separatedBy: "Sunshine version").last ?? ""
        return latest.contains("Found H.264 encoder")
    }

    /// 从 sunshine.log 判断最近一次启动是否有捕获权限错误
    static func checkSunshinePermission(logPath: String) -> (String, String) {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return ("⚠️ 无法读取 Sunshine 日志", logPath)
        }
        if sunshineProbeGranted(logPath: logPath) {
            return ("✅ Sunshine 捕获与编码", "屏幕捕获权限正常，VideoToolbox 硬件编码器就绪")
        }
        // 只看最后一次启动段：未出现编码器就绪且出现权限错误 → 权限缺失
        let latest = content.components(separatedBy: "Sunshine version").last ?? ""
        if latest.contains("No screen capture permission") {
            return ("❌ Sunshine 无屏幕捕获权限", "菜单 → 权限引导…，允许 MoonRise 后点「重启 Sunshine」")
        }
        return ("⚠️ 未在日志确认编码器状态", "如串流异常请看 \(logPath)")
    }
}
