// DiagnosticsWindow.swift — 诊断窗口：一键检查整条链路的各项前置条件。

import AppKit
import MoonRiseCore
import VirtualDisplayObjC

final class DiagnosticsWindow: NSWindow, NSWindowDelegate {
    private let textView = NSTextView()
    private var checks: [(String, String)] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        title = "诊断"
        delegate = self
        isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 460))
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

    struct DiagnosticsContext {
        let realized: RealizedDisplay?
        let liveDisplayIDs: [CGDirectDisplayID]
        let sunshineStatus: String
        let manager: SunshineManaging
        let sunshineConfigPath: String
    }

    static func runChecks(context: DiagnosticsContext) -> [(String, String)] {
        var results: [(String, String)] = []

        // 1. 私有 API
        if let error = VDVirtualDisplay.apiAvailabilityError() {
            results.append(("❌ 虚拟屏私有 API", error.localizedDescription))
        } else {
            results.append(("✅ 虚拟屏私有 API", "macOS 私有类与 selector 全部在位"))
        }

        // 2. 虚拟屏
        if let display = context.realized, context.liveDisplayIDs.contains(display.displayID) {
            let spec = display.spec
            results.append((
                "✅ 虚拟屏",
                "\(spec.name) id=\(display.displayID) \(spec.width)x\(spec.height)@\(spec.refreshRate)（在活动列表中）"
            ))
        } else if let display = context.realized {
            results.append(("⚠️ 虚拟屏", "id=\(display.displayID) 已不在活动列表（看门狗应会自动重建）"))
        } else {
            results.append(("❌ 虚拟屏", "未创建"))
        }

        // 3. Sunshine 安装
        if let install = context.manager.detect() {
            results.append(("✅ Sunshine 安装", install.binaryPath))
        } else {
            results.append(("❌ Sunshine 未安装", "brew tap lizardbyte/homebrew && brew install lizardbyte/homebrew/sunshine"))
        }

        // 4. Sunshine 配置联动
        let confPath = Paths.expandTilde(context.sunshineConfigPath)
        if FileManager.default.fileExists(atPath: confPath) {
            let text = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
            let configured = ConfFile.readValue(in: text, key: "output_name")
            let expected = context.realized.map { String($0.displayID) }
            if configured == expected, let expected {
                results.append(("✅ output_name 同步", "output_name = \(expected)"))
            } else {
                results.append((
                    "⚠️ output_name 不一致",
                    "配置=\(configured ?? "（无）") 期望=\(expected ?? "（无屏）")；菜单 → Sunshine → 重新同步"
                ))
            }
        } else {
            results.append(("⚠️ sunshine.conf 不存在", confPath + "（先启动一次 Sunshine）"))
        }

        // 5a. MoonRise 屏幕捕获权限（本进程 preflight，权威）
        let granted = CapturePermission.granted
        results.append((
            granted ? "✅ MoonRise 屏幕捕获权限" : "❌ MoonRise 屏幕捕获权限",
            granted ? "已授予" : "未授予——启动时的系统弹窗允许，或系统设置打开 MoonRise 开关"
        ))

        // 5b. Sunshine 捕获权限（从最近日志推断，无法直接读 TCC）
        let logResult = checkSunshinePermission(logPath: Paths.expandTilde("~/.config/sunshine/sunshine.log"))
        results.append(logResult)

        // 6. Retina 指引
        if let display = context.realized {
            let spec = display.spec
            results.append((
                "ℹ️ Retina 指引",
                "系统设置 → 显示器 选中 \(spec.name)，分辨率选 \(spec.logicalWidth)×\(spec.logicalHeight)"
                    + "（“看起来像”）；Moon 端 Moonlight 设 \(spec.width)×\(spec.height)@\(spec.refreshRate) H.264 全屏"
            ))
        }

        // 7. 外接显示器清单（便于发现 Duet 等虚拟屏干扰）
        let externals = Self.externalDisplaySummary(liveIDs: context.liveDisplayIDs)
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
