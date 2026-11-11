// PermissionPanel.swift — 权限引导窗口（SwiftUI）：四步检查单 + 就地动作 + 每秒刷新。
// 权限对象是 MoonRise（Sunshine 以子进程运行，macOS 按责任进程向 MoonRise 收权限）。
// 启动时检测到权限缺失自动弹出（AppController）。

import AppKit
import SwiftUI
import MoonRiseCore

final class PermissionPanel: NSWindow {
    struct Context {
        let manager: SunshineManaging
        let sunshineLogPath: String
        let restartSunshine: () -> Void
    }

    private var context: Context?
    private var appliedContentHeight: CGFloat = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        title = "权限引导"
        identifier = NSUserInterfaceItemIdentifier("moonrise.permission")
        isReleasedWhenClosed = false
        var view = PermissionView(
            statusProvider: { [weak self] in self?.statusSnapshot() },
            actions: PermissionView.Actions(
                requestCapture: { CapturePermission.request() },
                requestInputControl: { CapturePermission.requestInputControl() },
                openSystemSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.privacy?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                },
                restartSunshine: { [weak self] in
                    self?.context?.restartSunshine()
                }))
        view.onContentHeight = { [weak self] height in
            self?.applyContentHeight(height)
        }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        contentView = hosting.view
        center()
    }

    func present(context: Context) {
        self.context = context
        NSApp.setActivationPolicy(.regular)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 权限状态快照（主线程每秒采集）。
    private func statusSnapshot() -> PermissionView.Status {
        let sunshine = context?.manager.statusLine() ?? "未知"
        return PermissionView.Status(
            captureGranted: CapturePermission.granted,
            inputGranted: CapturePermission.inputControlGranted,
            sunshineRunning: sunshine.hasPrefix("运行中"),
            sunshineStatusLine: sunshine,
            probeOK: DiagnosticsModel.sunshineProbeGranted(logPath: context?.sunshineLogPath ?? ""))
    }

    /// 窗口高度 = 实测内容高度（+28 标题栏），钳制后设框并居中主屏。
    private func applyContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let visible = primaryVisibleFrame()
        let target = min(max(height + 28, 280), max(280, visible.height - 24))
        guard abs(target - appliedContentHeight) > 1 else { return }
        appliedContentHeight = target
        var frame = frame
        frame.size.height = target
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - target / 2
        setFrame(frame, display: true, animate: false)
    }
}

struct PermissionView: View {
    struct Actions {
        let requestCapture: () -> Void
        let requestInputControl: () -> Void
        let openSystemSettings: () -> Void
        let restartSunshine: () -> Void
    }

    struct Status {
        let captureGranted: Bool
        let inputGranted: Bool
        let sunshineRunning: Bool
        let sunshineStatusLine: String
        let probeOK: Bool
    }

    let statusProvider: () -> Status?
    let actions: Actions
    var onContentHeight: ((CGFloat) -> Void)?

    @State private var status = Status(
        captureGranted: false, inputGranted: false,
        sunshineRunning: false, sunshineStatusLine: "", probeOK: false)
    private let heartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                checkRow(status.captureGranted, symbol: "lock.shield",
                         title: "屏幕捕获（MoonRise）",
                         detail: status.captureGranted
                             ? "已授予（全部实例共用该归属）"
                             : "未授予——允许系统弹窗，或在系统设置打开 MoonRise 开关") {
                    if !status.captureGranted {
                        Button("请求屏幕捕获授权") { actions.requestCapture() }
                        Button("打开系统设置") { actions.openSystemSettings() }
                    }
                }
                Divider()
                checkRow(status.inputGranted, symbol: "keyboard",
                         title: "输入控制（MoonRise）",
                         detail: status.inputGranted
                             ? "已授予"
                             : "未授予——Moon 端键鼠控制需要；系统设置打开 MoonRise 开关") {
                    if !status.inputGranted {
                        Button("请求输入控制授权") { actions.requestInputControl() }
                        Button("打开系统设置") { actions.openSystemSettings() }
                    }
                }
                Divider()
                checkRow(status.sunshineRunning, symbol: "bolt.horizontal",
                         title: "Sunshine 进程",
                         detail: status.sunshineStatusLine) {}
                Divider()
                checkRow(status.probeOK, symbol: "video",
                         title: "编码器探测",
                         detail: status.probeOK
                             ? "捕获就绪，VideoToolbox 硬件编码器就绪"
                             : "未通过（需要权限或重启）") {
                    if !status.probeOK {
                        Button("重启 Sunshine") { actions.restartSunshine() }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))

            Text(guidance)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ListContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ListContentHeightKey.self) { height in
            onContentHeight?(height)
        }
        .onAppear { refresh() }
        .onReceive(heartbeat) { _ in refresh() }
    }

    private func refresh() {
        if let snapshot = statusProvider() {
            status = snapshot
        }
    }

    private func checkRow<Trailing: View>(_ ok: Bool, symbol: String, title: String,
                                          detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
                .font(.system(size: 16))
            Image(systemName: symbol)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var guidance: String {
        if !status.captureGranted || !status.inputGranted {
            var steps = "权限对象是 MoonRise（Sunshine 以子进程运行，macOS 按责任进程向 MoonRise 收权限；给 sunshine 二进制授权无效）。"
            if !status.captureGranted {
                steps += " ① 屏幕捕获：点「请求屏幕捕获授权」→ 弹窗点「允许」。"
            }
            if !status.inputGranted {
                steps += " ② 输入控制：点「请求输入控制授权」→ 系统设置中打开 MoonRise 开关（Moon 端键鼠控制需要）。"
            }
            steps += " 完成后本窗口数秒内自动变绿，Sunshine 会自动重启。"
            return steps
        }
        if !status.probeOK {
            return "权限已全部授予 ✓。Sunshine 需要重启以重跑编码器探测：点「重启 Sunshine」。（授权翻转时通常已自动完成）"
        }
        return "全部就绪 ✓：可在 Moon 端 Moonlight 全屏连接本机，验证扩展屏。"
    }
}
