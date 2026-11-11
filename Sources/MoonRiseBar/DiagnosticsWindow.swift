// DiagnosticsWindow.swift — 诊断检查模型：设置窗口诊断页的数据源（AppKit 窗口已由页面取代）。
// 检查项沿用：私有 API / 逐屏虚拟屏 / Sunshine 安装 / output_name 一致性 /
// 屏幕捕获权限 preflight / 编码器探测逐实例日志 / Retina 指引 / 外接显示器清单。

import CoreGraphics
import Foundation
import MoonRiseCore
import VirtualDisplayObjC

enum DiagnosticsModel {
    enum Status {
        case ok, warn, err, info

        var badge: String {
            switch self {
            case .ok: return "✅"
            case .warn: return "⚠️"
            case .err: return "❌"
            case .info: return "ℹ️"
            }
        }
    }

    struct CheckRow {
        let symbol: String   // SF Symbol（页面行首图标）
        let title: String
        let detail: String
        let status: Status
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

    struct Context {
        let screens: [ScreenDiagnostics]
        let sunshineStatus: String
        let manager: SunshineManaging
    }

    // MARK: - 检查（纯读文件与系统状态，可在后台队列执行）

    static func runChecks(context: Context) -> [CheckRow] {
        var rows: [CheckRow] = []

        // 1. 私有 API
        if let error = VDVirtualDisplay.apiAvailabilityError() {
            rows.append(CheckRow(symbol: "cpu", title: "虚拟屏私有 API",
                                 detail: error.localizedDescription, status: .err))
        } else {
            rows.append(CheckRow(symbol: "cpu", title: "虚拟屏私有 API",
                                 detail: "macOS 私有类与 selector 全部在位", status: .ok))
        }

        // 2. 虚拟屏（逐屏）
        let enabledScreens = context.screens.filter(\.enabled)
        if enabledScreens.isEmpty {
            rows.append(CheckRow(symbol: "display", title: "虚拟屏",
                                 detail: "无已启用屏幕", status: .warn))
        }
        for screen in enabledScreens {
            let spec = screen.spec
            if let displayID = screen.displayID, screen.isLive {
                rows.append(CheckRow(symbol: "display", title: "虚拟屏 · \(screen.name)",
                                     detail: "id=\(displayID) · \(spec.width)×\(spec.height)@\(spec.refreshRate)（活动列表中）",
                                     status: .ok))
            } else if screen.displayID != nil {
                rows.append(CheckRow(symbol: "display", title: "虚拟屏 · \(screen.name)",
                                     detail: "id=\(screen.displayID!) 已不在活动列表（看门狗会自动重建）",
                                     status: .warn))
            } else {
                rows.append(CheckRow(symbol: "display", title: "虚拟屏 · \(screen.name)",
                                     detail: "未创建", status: .err))
            }
        }

        // 3. Sunshine 安装
        if let install = context.manager.detect() {
            rows.append(CheckRow(symbol: "shippingbox", title: "Sunshine 安装",
                                 detail: install.binaryPath, status: .ok))
        } else {
            rows.append(CheckRow(symbol: "shippingbox", title: "Sunshine 安装",
                                 detail: "未安装——brew tap lizardbyte/homebrew && brew install lizardbyte/homebrew/sunshine",
                                 status: .err))
        }

        // 4. output_name 逐屏一致性：首屏主 conf；扩展屏实例 conf
        let mainConfPath = Paths.expandTilde("~/.config/sunshine/sunshine.conf")
        for screen in enabledScreens {
            let expected = screen.displayID.map { String($0) }
            let confPath = screen.port == nil ? mainConfPath : InstanceConf.confURL(for: screen.slotID).path
            if FileManager.default.fileExists(atPath: confPath) {
                let text = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
                let configured = ConfFile.readValue(in: text, key: "output_name")
                if configured == expected, let expected {
                    rows.append(CheckRow(symbol: "doc.text", title: "output_name · \(screen.name)",
                                         detail: "\(confPath) → \(expected)", status: .ok))
                } else {
                    rows.append(CheckRow(symbol: "doc.text", title: "output_name 不一致 · \(screen.name)",
                                         detail: "配置=\(configured ?? "（无）") 期望=\(expected ?? "（无屏）")；设置通用页点「同步」重新对账",
                                         status: .warn))
                }
            } else {
                let hint = screen.port == nil ? "（先启动一次 Sunshine）" : "（实例 conf 由 MoonRise 代建，通用页点「同步」即可）"
                rows.append(CheckRow(symbol: "doc.text", title: "conf 不存在 · \(screen.name)",
                                     detail: confPath + hint, status: .warn))
            }
        }

        // 5. 屏幕捕获权限（MoonRise 本进程 preflight，权威；全部实例共用归属）
        let granted = CapturePermission.granted
        rows.append(CheckRow(symbol: "lock.shield", title: "屏幕捕获权限（MoonRise）",
                             detail: granted
                                 ? "已授予（全部实例共用该归属）"
                                 : "未授予——权限引导里允许 MoonRise，或系统设置打开 MoonRise 开关",
                             status: granted ? .ok : .err))

        // 6. 编码器探测（逐屏日志：首屏主实例日志，扩展屏实例日志）
        let primaryLog: String = {
            let child = Paths.stateDirectory.appendingPathComponent("sunshine-child.log").path
            return FileManager.default.fileExists(atPath: child)
                ? child
                : Paths.expandTilde("~/.config/sunshine/sunshine.log")
        }()
        for screen in enabledScreens {
            let logPath = screen.port == nil ? primaryLog : InstanceConf.logURL(for: screen.slotID).path
            rows.append(probeRow(title: "编码器探测 · \(screen.name)", logPath: logPath))
        }

        // 7. Retina 指引（逐屏）
        for screen in enabledScreens {
            let spec = screen.spec
            let note = spec.hiDPI
                ? "分辨率选 \(spec.logicalWidth)×\(spec.logicalHeight)（“看起来像”）"
                : "分辨率选 \(spec.width)×\(spec.height)（HiDPI 已关闭）"
            rows.append(CheckRow(symbol: "text.magnifyingglass", title: "Retina 指引 · \(screen.name)",
                                 detail: "系统设置 → 显示器 选中 \(spec.name)，\(note)；Moon 端 Moonlight 设 \(spec.width)×\(spec.height)@\(spec.refreshRate) H.264 全屏",
                                 status: .info))
        }

        // 8. 外接显示器清单（便于发现 Duet 等虚拟屏干扰）
        let liveIDs = context.screens.compactMap { $0.isLive ? $0.displayID : nil }
        let externals = externalDisplaySummary(liveIDs: liveIDs)
        if externals.isEmpty {
            rows.append(CheckRow(symbol: "display.2", title: "外接显示器清单",
                                 detail: "无其他外接显示器", status: .info))
        } else {
            rows.append(CheckRow(symbol: "display.2", title: "外接显示器清单",
                                 detail: externals.joined(separator: "、") + "（如含 Duet 等虚拟屏且不再使用，建议禁用以免混淆）",
                                 status: .info))
        }

        return rows
    }

    /// 编码器探测行（单实例日志：探测通过为权威权限事实）。
    static func probeRow(title: String, logPath: String) -> CheckRow {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return CheckRow(symbol: "video", title: title,
                            detail: "无法读取日志 \(logPath)", status: .warn)
        }
        if sunshineProbeGranted(logPath: logPath) {
            return CheckRow(symbol: "video", title: title,
                            detail: "捕获权限正常，VideoToolbox 硬件编码器就绪", status: .ok)
        }
        let latest = content.components(separatedBy: "Sunshine version").last ?? ""
        if latest.contains("No screen capture permission") {
            return CheckRow(symbol: "video", title: title,
                            detail: "无屏幕捕获权限——权限引导里允许 MoonRise 后重启该实例", status: .err)
        }
        return CheckRow(symbol: "video", title: title,
                        detail: "未在日志确认编码器状态（如串流异常查看 \(logPath)）", status: .warn)
    }

    /// 最近一次启动的编码器探测是否通过（权限已生效的事实检验）。
    static func sunshineProbeGranted(logPath: String) -> Bool {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return false
        }
        let latest = content.components(separatedBy: "Sunshine version").last ?? ""
        return latest.contains("Found H.264 encoder")
    }

    /// 除 moonrise 屏与内建屏之外的全部显示器（vendor=hex 尺寸）。
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
}
