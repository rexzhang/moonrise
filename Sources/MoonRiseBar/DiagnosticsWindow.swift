// DiagnosticsWindow.swift — 诊断检查模型：设置窗口诊断页的数据源（AppKit 窗口已由页面取代）。
// 组织：先公共组（私有 API / 屏幕捕获权限 / Sunshine 受管副本），后按屏组
// （虚拟屏 / output_name 一致性 / 编码器探测，组头 = 屏幕名，键 = slotID）。

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

    /// 诊断分组：header = nil 为公共组；否则组头为屏幕名（按屏组，键 = slotID）。
    struct CheckSection: Identifiable {
        let header: String?
        let slotID: UUID?
        let rows: [CheckRow]

        var id: String { header ?? slotID?.uuidString ?? "common" }
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
    }

    // MARK: - 检查（纯读文件与系统状态，可在后台队列执行）

    static func runChecks(context: Context) -> [CheckSection] {
        var sections: [CheckSection] = []

        // 公共组
        var common: [CheckRow] = []
        if let error = VDVirtualDisplay.apiAvailabilityError() {
            common.append(CheckRow(symbol: "cpu", title: "虚拟屏私有 API",
                                   detail: error.localizedDescription, status: .err))
        } else {
            common.append(CheckRow(symbol: "cpu", title: "虚拟屏私有 API",
                                   detail: "macOS 私有类与 selector 全部在位", status: .ok))
        }
        let granted = CapturePermission.granted
        common.append(CheckRow(symbol: "lock.shield", title: "屏幕捕获权限（MoonRise）",
                               detail: granted
                                   ? "已授予（全部实例共用该归属）"
                                   : "未授予——权限引导里允许 MoonRise，或系统设置打开 MoonRise 开关",
                               status: granted ? .ok : .err))
        if ManagedSunshineStore.isReady() {
            common.append(CheckRow(symbol: "shippingbox", title: "Sunshine 受管副本",
                                   detail: Paths.managedSunshineBundleURL.path, status: .ok))
        } else {
            common.append(CheckRow(symbol: "shippingbox", title: "Sunshine 受管副本",
                                   detail: "未获取——设置 → Sunshine 页点「获取」", status: .err))
        }
        sections.append(CheckSection(header: nil, slotID: nil, rows: common))

        // 按屏组（已启用屏；停用屏不产生检查行）
        let enabledScreens = context.screens.filter(\.enabled)
        let mainConfPath = Paths.expandTilde("~/.config/sunshine/sunshine.conf")
        let primaryLog: String = {
            let child = Paths.stateDirectory.appendingPathComponent("sunshine-child.log").path
            return FileManager.default.fileExists(atPath: child)
                ? child
                : Paths.expandTilde("~/.config/sunshine/sunshine.log")
        }()

        for screen in enabledScreens {
            var rows: [CheckRow] = []

            // 虚拟屏
            let spec = screen.spec
            if let displayID = screen.displayID, screen.isLive {
                rows.append(CheckRow(symbol: "display", title: "虚拟屏",
                                     detail: "id=\(displayID) · \(spec.width)×\(spec.height)@\(spec.refreshRate)（活动列表中）",
                                     status: .ok))
            } else if screen.displayID != nil {
                rows.append(CheckRow(symbol: "display", title: "虚拟屏",
                                     detail: "id=\(screen.displayID!) 已不在活动列表（看门狗会自动重建）",
                                     status: .warn))
            } else {
                rows.append(CheckRow(symbol: "display", title: "虚拟屏",
                                     detail: "未创建", status: .err))
            }

            // output_name 一致性（首屏主 conf；扩展屏实例 conf）
            let expected = screen.displayID.map { String($0) }
            let confPath = screen.port == nil ? mainConfPath : InstanceConf.confURL(for: screen.slotID).path
            if FileManager.default.fileExists(atPath: confPath) {
                let text = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
                let configured = ConfFile.readValue(in: text, key: "output_name")
                if configured == expected, let expected {
                    rows.append(CheckRow(symbol: "doc.text", title: "output_name",
                                         detail: "\(confPath) → \(expected)", status: .ok))
                } else {
                    rows.append(CheckRow(symbol: "doc.text", title: "output_name 不一致",
                                         detail: "配置=\(configured ?? "（无）") 期望=\(expected ?? "（无屏）")；通用页点「同步」重新对账",
                                         status: .warn))
                }
            } else {
                let hint = screen.port == nil ? "（主 conf 由 MoonRise 代建，通用页点「同步」即可）" : "（实例 conf 由 MoonRise 代建，通用页点「同步」即可）"
                rows.append(CheckRow(symbol: "doc.text", title: "conf 不存在",
                                     detail: confPath + hint, status: .warn))
            }

            // 编码器探测（首屏主实例日志；扩展屏实例日志）
            let logPath = screen.port == nil ? primaryLog : InstanceConf.logURL(for: screen.slotID).path
            rows.append(probeRow(title: "编码器探测", logPath: logPath))

            sections.append(CheckSection(header: screen.name, slotID: screen.slotID, rows: rows))
        }

        return sections
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
}
