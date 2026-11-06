// PermissionPanel.swift — 权限引导面板：实时监控屏幕捕获与输入控制授权、
// 分步指引完成添加。只为主要 macOS（系统设置/设备控制和数据访问时代）设计。

import AppKit
import ApplicationServices
import MoonRiseCore

final class PermissionPanel: NSWindow, NSWindowDelegate {
    struct Context {
        let manager: SunshineManaging
        let sunshineLogPath: String
        let restartSunshine: () -> Void
    }

    private let captureRow = NSTextField(labelWithString: "")
    private let inputRow = NSTextField(labelWithString: "")
    private let sunshineRow = NSTextField(labelWithString: "")
    private let probeRow = NSTextField(labelWithString: "")
    private let guideText = NSTextField(wrappingLabelWithString: "")
    private var context: Context?
    private var refreshTimer: Timer?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        title = "权限引导"
        delegate = self
        isReleasedWhenClosed = false
        buildContent()
        center()
    }

    func present(context: Context) {
        self.context = context
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 330))
        contentView = content

        guideText.font = NSFont.systemFont(ofSize: 12)
        guideText.preferredMaxLayoutWidth = 470

        let rows = NSStackView(views: [captureRow, inputRow, sunshineRow, probeRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)

        guideText.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(guideText)

        let captureButton = NSButton(title: "请求屏幕捕获授权", target: self, action: #selector(requestCaptureAuth))
        captureButton.bezelStyle = .rounded
        let inputButton = NSButton(title: "请求输入控制授权", target: self, action: #selector(requestInputAuth))
        inputButton.bezelStyle = .rounded
        let settingsButton = NSButton(title: "打开系统设置", target: self, action: #selector(openSystemSettings))
        settingsButton.bezelStyle = .rounded
        let restartButton = NSButton(title: "重启 Sunshine", target: self, action: #selector(restartSunshine))
        restartButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [captureButton, inputButton, settingsButton, restartButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            guideText.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 14),
            guideText.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            guideText.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: guideText.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    // MARK: - 状态刷新（每秒）

    private func refresh() {
        guard let context, isVisible else { return }

        let captureGranted = CapturePermission.granted
        captureRow.stringValue = captureGranted
            ? "✅ 屏幕捕获（MoonRise）：已授予"
            : "❌ 屏幕捕获（MoonRise）：未授予"
        captureRow.textColor = captureGranted ? .systemGreen : .systemRed

        let inputGranted = CapturePermission.inputControlGranted
        inputRow.stringValue = inputGranted
            ? "✅ 输入控制（设备控制和数据访问）：已授予"
            : "❌ 输入控制（设备控制和数据访问）：未授予"
        inputRow.textColor = inputGranted ? .systemGreen : .systemRed

        let sunshine = context.manager.statusLine()
        sunshineRow.stringValue = sunshine.hasPrefix("运行中")
            ? "✅ Sunshine 进程：\(sunshine)"
            : "⏳ Sunshine 进程：\(sunshine)"
        sunshineRow.textColor = sunshine.hasPrefix("运行中") ? .systemGreen : .secondaryLabelColor

        let probeOK = DiagnosticsWindow.sunshineProbeGranted(logPath: context.sunshineLogPath)
        probeRow.stringValue = probeOK
            ? "✅ Sunshine 编码探测：捕获就绪"
            : "❌ Sunshine 编码探测：未通过（需要权限或重启）"
        probeRow.textColor = probeOK ? .systemGreen : .systemRed

        guideText.stringValue = guidance(
            captureGranted: captureGranted, inputGranted: inputGranted, probeOK: probeOK)
    }

    private func guidance(captureGranted: Bool, inputGranted: Bool, probeOK: Bool) -> String {
        if !captureGranted || !inputGranted {
            var steps = "权限对象是 MoonRise（Sunshine 以子进程运行，macOS 按责任进程向 MoonRise 收权限；给 sunshine 二进制授权无效）。\n"
            if !captureGranted {
                steps += "① 屏幕捕获：点「请求屏幕捕获授权」→ 弹窗点「允许」；或在设备控制和数据访问面板添加 /Applications/MoonRise.app 并打开开关。\n"
            }
            if !inputGranted {
                steps += "② 输入控制：点「请求输入控制授权」→ 系统设置中打开 MoonRise 开关（Moon 端键鼠控制需要）。\n"
            }
            steps += "完成后本面板数秒内自动变绿，Sunshine 会自动重启。"
            return steps
        }
        if !probeOK {
            return "权限已全部授予 ✓。Sunshine 需要重启以重跑编码器探测：点「重启 Sunshine」。（授权翻转时通常已自动完成）"
        }
        return "全部就绪 ✓：可在 Moon 端 Moonlight 全屏连接本机，验证扩展屏。"
    }

    // MARK: - 动作

    @objc private func requestCaptureAuth() {
        CapturePermission.request()
    }

    @objc private func requestInputAuth() {
        CapturePermission.requestInputControl()
    }

    @objc private func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.privacy?Privacy_ScreenCapture")!)
    }

    @objc private func restartSunshine() {
        context?.restartSunshine()
    }
}
