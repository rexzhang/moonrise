// SettingsWindow.swift — MoonRise 设置窗口（SwiftUI）：侧边栏三页面（通用 / 屏幕 / 诊断，
// macOS 系统设置风格）+ 屏幕修改 / 配对子窗口宿主。菜单栏「设置…」打开。
// 窗口自动居中主屏、内容驱动高度（实测 + setFrame）；激活策略随窗口开关切换（.regular / .accessory）。

import AppKit
import CoreServices
import SwiftUI
import MoonRiseCore

// MARK: - 页面定义

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case screens
    case permission
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .screens: return "屏幕管理"
        case .permission: return "权限"
        case .diagnostics: return "诊断"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .screens: return "rectangle.on.rectangle"
        case .permission: return "lock.shield"
        case .diagnostics: return "stethoscope"
        }
    }
}

// MARK: - 行内动作接线（AppController 组装）

struct ScreenCallbacks {
    /// 启用/停用（第二参：来自菜单行——失败走错误弹框；来自卡片——失败就地报错）。
    var toggleEnabled: ((DisplayConfig, Bool) -> Void)?
    var restartSlot: ((UUID) -> Void)?
    var openWebUI: ((Int) -> Void)?
    var openPairing: ((DisplayConfig) -> Void)?
    var openEdit: ((DisplayConfig) -> Void)?
    var deleteSlot: ((DisplayConfig) -> Void)?
    var openAdd: (() -> Void)?
    var setKeepHostScaling: ((Bool) -> Void)?
    var setDisableAudioStreaming: ((Bool) -> Void)?
    var setLoginItem: ((Bool) -> Void)?
    var restartAllInstances: (() -> Void)?
    var resyncAll: (() -> Void)?
    var requestCapturePermission: (() -> Void)?
    var requestInputControlPermission: (() -> Void)?
    var openCaptureSystemSettings: (() -> Void)?
    var restartPrimarySunshine: (() -> Void)?
}

/// 权限页状态快照（主线程每秒采集）。
struct PermissionStatusSnapshot {
    let captureGranted: Bool
    let inputGranted: Bool
    let sunshineRunning: Bool
    let sunshineStatusLine: String
    let probeOK: Bool
}

// MARK: - 状态模型

final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage = .screens
    @Published var displays: [DisplayConfig] = []
    @Published var summaries: [AppController.ScreenSummary] = []
    @Published var keepHostScaling = true
    @Published var disableAudioStreaming = false
    @Published var loginItemEnabled = false
    @Published var lanAddresses: [String] = []
    @Published var errors: [UUID: String] = [:]
    var callbacks = ScreenCallbacks()
    /// 诊断页数据源：主线程快照 → 后台检查 → 主线程回调（AppController 提供）。
    var diagnosticsProvider: ((@escaping ([DiagnosticsModel.CheckRow]) -> Void) -> Void)?
    /// 权限页数据源（AppController 提供，主线程采集）。
    var permissionProvider: (() -> PermissionStatusSnapshot?)?
    /// 页面内容实测尺寸回调（驱动窗口高度 + 居中）。
    var onContentSizeChanged: ((CGSize) -> Void)?

    func refresh(displays: [DisplayConfig],
                 summaries: [AppController.ScreenSummary],
                 keepHostScaling: Bool,
                 disableAudioStreaming: Bool,
                 loginItemEnabled: Bool,
                 lanAddresses: [String]) {
        DispatchQueue.main.async { [weak self] in
            self?.displays = displays
            self?.summaries = summaries
            self?.keepHostScaling = keepHostScaling
            self?.disableAudioStreaming = disableAudioStreaming
            self?.loginItemEnabled = loginItemEnabled
            self?.lanAddresses = lanAddresses
        }
    }

    func summary(for slotID: UUID) -> AppController.ScreenSummary? {
        summaries.first { $0.slotID == slotID }
    }

    /// 行内动作失败：卡片内就地错误行，保留至下次动作或 5s。
    func reportError(_ slotID: UUID, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errors[slotID] = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.errors[slotID] == message {
                self?.errors[slotID] = nil
            }
        }
    }
}

// MARK: - 宿主窗口

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    let model = SettingsModel()
    private let settingsWindow: NSWindow
    private var editWindows: [UUID: NSWindow] = [:]
    private var pairingWindows: [UUID: NSWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var appliedContentHeight: CGFloat = 0

    init() {
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        settingsWindow.title = "MoonRise 设置"
        settingsWindow.identifier = NSUserInterfaceItemIdentifier("moonrise.settings")
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.backgroundColor = NSColor.windowBackgroundColor
        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        hosting.sizingOptions = []
        // 用 contentView 挂载（不用 contentViewController——后者会让窗口采用
        // hosting 的 preferredContentSize，sizingOptions 为空时是 0×28，窗口塌缩）
        settingsWindow.contentView = hosting.view
        model.onContentSizeChanged = { [weak self] size in
            self?.setWindowSizeAndCenter(size)
        }
        // 项目 UI 标准：窗口尺寸变化（内容驱动）后自动居中。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  let id = window.identifier?.rawValue,
                  id.hasPrefix("moonrise.") else { return }
            centerOnMainScreen(window)
        })
        // 最后一个 MoonRise 窗口关闭 → 回到纯菜单栏形态（.accessory）。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let closing = note.object as? NSWindow else { return }
            // willClose 时窗口仍标记可见——异步等关闭完成后检查
            DispatchQueue.main.async {
                self?.updateActivationPolicy(excluding: closing)
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func showSettings(page: SettingsPage? = nil) {
        if let page {
            model.page = page
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 窗口尺寸 = 设计定宽 + 实测内容高度（+ 标题栏与页面边距），钳制后设框并居中主屏。
    private func setWindowSizeAndCenter(_ contentSize: CGSize) {
        guard contentSize.height.isFinite, contentSize.height > 0 else { return }
        let visible = primaryVisibleFrame()
        let targetWidth: CGFloat = 780
        // 72 = 标题栏 + 顶部 tab 条（分段控件，固定高度）；页面内容实测上报，余量不虚高
        let targetHeight = min(max(contentSize.height + 72, 320), max(320, visible.height - 24))
        guard abs(targetHeight - appliedContentHeight) > 1 else { return }
        appliedContentHeight = targetHeight
        var frame = settingsWindow.frame
        frame.size = NSSize(width: targetWidth, height: targetHeight)
        frame.origin.x = visible.midX - targetWidth / 2
        frame.origin.y = visible.midY - targetHeight / 2
        settingsWindow.setFrame(frame, display: true, animate: false)
    }

    /// 任一 MoonRise 窗口可见期间保持常规 App 形态，全部关闭后回到纯菜单栏形态。
    private func updateActivationPolicy(excluding closing: NSWindow? = nil) {
        let anyVisible = NSApp.windows.contains { window in
            window !== closing
                && window.isVisible
                && window.identifier?.rawValue.hasPrefix("moonrise.") == true
        }
        if !anyVisible {
            NSApp.setActivationPolicy(.accessory)
            // macOS 27 运行时切回附件不再移除 Dock 图标——用 TransformProcessType 强制 Dock 刷新
            var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(getpid()))
            TransformProcessType(&psn, ProcessApplicationTransformState(kProcessTransformToUIElementApplication))
        }
    }

    // MARK: - 修改窗口（复用置前）

    /// 修改窗口。onApply 的第二参为结果回调：非 nil = 失败就地报错；nil = 成功关窗。
    func openEdit(display: DisplayConfig, streaming: Bool, others: [DisplayConfig],
                  onApply: @escaping (DisplayConfig, @escaping (String?) -> Void) -> Void) {
        if let existing = editWindows[display.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "修改屏幕 — \(display.name)"
        window.identifier = NSUserInterfaceItemIdentifier("moonrise.edit.\(display.id.uuidString)")
        window.isReleasedWhenClosed = false
        let close = { [weak window, weak self] in
            window?.close()
            self?.editWindows[display.id] = nil
        }
        var editView = ScreenEditView(
            mode: .edit(display),
            streaming: streaming,
            others: others.filter { $0.id != display.id },
            onApply: { newDisplay, reportError in
                onApply(newDisplay) { errorMessage in
                    // 结果回到主线程：@State 更新与窗口关闭都要求主线程
                    DispatchQueue.main.async {
                        if let errorMessage {
                            reportError(errorMessage)
                        } else {
                            close()
                        }
                    }
                }
            },
            onClose: close)
        editView.onContentHeight = { [weak self, weak window] contentHeight in
            self?.setSubwindowSize(window, contentHeight: contentHeight, minWidth: 450)
        }
        window.contentViewController = NSHostingController(rootView: editView)
        editWindows[display.id] = window
        present(window)
    }

    func closeEdit(slotID: UUID) {
        editWindows[slotID]?.close()
        editWindows[slotID] = nil
    }

    /// 添加模式窗口（单例复用）。
    private var addWindow: NSWindow?
    func openAdd(initialName: String, others: [DisplayConfig],
                 onApply: @escaping (DisplayConfig, @escaping (String?) -> Void) -> Void) {
        if let existing = addWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "添加屏幕"
        window.identifier = NSUserInterfaceItemIdentifier("moonrise.add")
        window.isReleasedWhenClosed = false
        let close = { [weak window, weak self] in
            window?.close()
            self?.addWindow = nil
        }
        var addView = ScreenEditView(
            mode: .add(initialName: initialName),
            streaming: false,
            others: others,
            onApply: { newDisplay, reportError in
                onApply(newDisplay) { errorMessage in
                    DispatchQueue.main.async {
                        if let errorMessage {
                            reportError(errorMessage)
                        } else {
                            close()
                        }
                    }
                }
            },
            onClose: close)
        addView.onContentHeight = { [weak self, weak window] contentHeight in
            self?.setSubwindowSize(window, contentHeight: contentHeight, minWidth: 450)
        }
        window.contentViewController = NSHostingController(rootView: addView)
        addWindow = window
        present(window)
    }

    /// 配对窗口（复用置前）。
    func openPairing(display: DisplayConfig) {
        if let existing = pairingWindows[display.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 140),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "配对 — \(display.name)"
        window.identifier = NSUserInterfaceItemIdentifier("moonrise.pairing.\(display.id.uuidString)")
        window.isReleasedWhenClosed = false
        let webPort = (display.sunshinePort ?? 47989) + 1
        var pairingView = PairingView(
            slotID: display.id,
            screenName: display.name,
            webPort: webPort,
            isPrimary: display.sunshinePort == nil,
            onClose: { [weak window, weak self] in
                window?.close()
                self?.pairingWindows[display.id] = nil
            })
        pairingView.onContentHeight = { [weak self, weak window] contentHeight in
            self?.setSubwindowSize(window, contentHeight: contentHeight, minWidth: 350)
        }
        window.contentViewController = NSHostingController(rootView: pairingView)
        pairingWindows[display.id] = window
        present(window)
    }

    /// 子窗口前置 + 常规 App 形态。
    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 子窗口高度 = 实测内容高度（+28 标题栏），钳制后设框并居中主屏。
    private func setSubwindowSize(_ window: NSWindow?, contentHeight: CGFloat, minWidth: CGFloat) {
        guard let window, window.isVisible, contentHeight.isFinite, contentHeight >= 0 else { return }
        let visible = primaryVisibleFrame()
        let target = min(max(contentHeight + 28, 280), max(280, visible.height - 24))
        var frame = window.frame
        frame.size.width = max(frame.width, minWidth)
        guard abs(frame.height - target) > 1 else { return }
        frame.origin.x = visible.midX - frame.size.width / 2
        frame.origin.y = visible.midY - target / 2
        frame.size.height = target
        window.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - 布局助手

/// 项目 UI 标准：窗口在主屏可视区内居中。
func centerOnMainScreen(_ window: NSWindow) {
    let visible = primaryVisibleFrame()
    var frame = window.frame
    frame.origin.x = visible.midX - frame.width / 2
    frame.origin.y = visible.midY - frame.height / 2
    window.setFrame(frame, display: true, animate: false)
}

/// 主屏（origin 0,0 的显示器）可视区。
func primaryVisibleFrame() -> NSRect {
    let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    return primary?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1055)
}

/// 页面内容实测尺寸上报（驱动设置窗口高度）。
struct ContentSizeReporter: ViewModifier {
    let onChange: (CGSize) -> Void

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ListContentSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(ListContentSizeKey.self) { size in
                onChange(size)
            }
    }
}

// MARK: - 根视图（顶部页面 tab + 页面内容；tab 条高度计入窗口高度常量）

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.page) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                switch model.page {
                case .general: GeneralPageView(model: model)
                case .screens: ScreensPageView(model: model)
                case .permission: PermissionPageView(model: model)
                case .diagnostics: DiagnosticsPageView(model: model)
                }
            }
        }
    }
}

// MARK: - 通用构件（富行 / 分组框，macOS 系统设置分组行式）

/// 富行：图标 + 标题 + 描述小字 + 尾部控件。
struct RichRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// 分组框：组标题 + 圆角容器（行间 Divider）。
struct SettingsGroupBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(.secondary)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        }
    }
}

// MARK: - 通用页面

struct GeneralPageView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroupBox(title: "显示器") {
                RichRow(symbol: "display", title: "保持显示器缩放",
                        detail: "拓扑变化后恢复 host 缩放，防低分辨率闪烁") {
                    Toggle("", isOn: keepBinding).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroupBox(title: "串流") {
                RichRow(symbol: "speaker.slash", title: "禁用音频串流",
                        detail: "同步写入主 conf 与全部实例 conf（值变才重启）") {
                    Toggle("", isOn: audioBinding).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroupBox(title: "系统") {
                RichRow(symbol: "power", title: "开机自启",
                        detail: "登录时自动启动 MoonRise（菜单栏无此项）") {
                    Toggle("", isOn: loginBinding).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                RichRow(symbol: "arrow.triangle.2.circlepath", title: "重启全部实例",
                        detail: "全部屏实例串行重启") {
                    Button("重启") { model.callbacks.restartAllInstances?() }
                }
                Divider()
                RichRow(symbol: "arrow.clockwise", title: "重新同步",
                        detail: "diff 收敛 + 逐实例 conf 对账，值变才重启") {
                    Button("同步") { model.callbacks.resyncAll?() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ContentSizeReporter { size in model.onContentSizeChanged?(size) })
    }

    private var keepBinding: Binding<Bool> {
        Binding(
            get: { model.keepHostScaling },
            set: { newValue in
                model.keepHostScaling = newValue
                model.callbacks.setKeepHostScaling?(newValue)
            })
    }

    private var audioBinding: Binding<Bool> {
        Binding(
            get: { model.disableAudioStreaming },
            set: { newValue in
                model.disableAudioStreaming = newValue
                model.callbacks.setDisableAudioStreaming?(newValue)
            })
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { model.loginItemEnabled },
            set: { newValue in
                model.loginItemEnabled = newValue
                model.callbacks.setLoginItem?(newValue)
            })
    }
}

// MARK: - 屏幕页面

struct ScreensPageView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ipSection
            HStack {
                Button("添加屏幕…") { model.callbacks.openAdd?() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Text("状态每秒自动刷新")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            let sorted = model.displays.sorted { $0.slotNumber < $1.slotNumber }
            if sorted.isEmpty {
                emptyState
            }
            ForEach(sorted) { display in
                ScreenCard(
                    display: display,
                    summary: model.summary(for: display.id),
                    error: model.errors[display.id],
                    callbacks: model.callbacks)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ContentSizeReporter { size in model.onContentSizeChanged?(size) })
    }

    /// 公共信息：本机全部有效 IPv4（多屏共用，只展示）。
    private var ipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本机 IP 地址 · 多屏共用")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                ForEach(model.lanAddresses, id: \.self) { ip in
                    Text(ip)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("还没有扩展屏幕")
                .font(.headline)
            Text("点上方「添加屏幕…」创建第一块屏：可选 MacBook / iPad 等预设，或自定义规格。创建后在 Moonlight 手动添加对应的 IP:端口 即可连接。")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// 单屏卡片：状态胶囊 + 信息行 + 行内控件 + 错误行。
private struct ScreenCard: View {
    let display: DisplayConfig
    let summary: AppController.ScreenSummary?
    let error: String?
    let callbacks: ScreenCallbacks

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(specText)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            actionRow
            if let error {
                Text("✗ \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .opacity(display.enabled ? 1 : 0.62)
    }

    private var header: some View {
        HStack {
            statePill
            Text(display.name).fontWeight(.semibold)
            Text("端口 \(display.sunshinePort ?? 47989)")
                .foregroundColor(.secondary)
                .font(.caption)
            Spacer()
            Text(summary?.syncStatus ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// 规格行：宽×高 · 刷新率 Hz · HiDPI · 等效 宽/2×高/2（HiDPI 关闭时无后两段）。
    private var specText: String {
        var parts = ["\(display.width)×\(display.height)", "\(display.refreshRate) Hz"]
        if display.hiDPI {
            parts.append("HiDPI")
            parts.append("等效 \(display.width / 2)×\(display.height / 2)")
        }
        return parts.joined(separator: " · ")
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Toggle("启用", isOn: enabledBinding)
                .toggleStyle(.switch)
                .font(.caption)
            Button("重启串流") { callbacks.restartSlot?(display.id) }
                .disabled(!display.enabled)
            Button("Web UI") { callbacks.openWebUI?((display.sunshinePort ?? 47989) + 1) }
                .disabled(!display.enabled)
            Button("配对…") { callbacks.openPairing?(display) }
                .disabled(!display.enabled)
            Button("修改…") { callbacks.openEdit?(display) }
            Button("删除（销屏并清理）") { callbacks.deleteSlot?(display) }
                .foregroundColor(.red)
                .disabled(display.sunshinePort == nil)
        }
        .font(.caption)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { display.enabled },
            set: { newValue in
                guard newValue != display.enabled else { return }
                var updated = display
                updated.enabled = newValue
                callbacks.toggleEnabled?(updated, false)
            })
    }

    /// 状态胶囊（四态）。
    @ViewBuilder
    private var statePill: some View {
        let state = summary?.state ?? (display.enabled ? ScreenState.offline : .disabled)
        let base = Text(state.label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        switch state {
        case .streaming:
            base.background(Capsule().fill(Color.green)).foregroundColor(.white)
        case .offline:
            base.background(Capsule().fill(Color.orange)).foregroundColor(.white)
        case .idle:
            base.overlay(Capsule().stroke(Color.secondary, lineWidth: 1)).foregroundColor(.secondary)
        case .disabled:
            base.overlay(Capsule().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3]))).foregroundColor(.secondary)
        }
    }
}

// MARK: - 诊断页面

struct DiagnosticsPageView: View {
    @ObservedObject var model: SettingsModel
    @State private var loading = true
    @State private var rows: [DiagnosticsModel.CheckRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检查…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 40)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        RichRow(symbol: rows[index].symbol,
                                title: rows[index].title,
                                detail: rows[index].detail) {
                            Text(rows[index].status.badge).font(.caption)
                        }
                        if index < rows.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                Button("重新检查") { reload() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ContentSizeReporter { size in model.onContentSizeChanged?(size) })
        .task { reload() }
    }

    /// 切入即检查 / 手动重跑（后台执行，主线程回调）。
    private func reload() {
        guard let provider = model.diagnosticsProvider else { return }
        loading = true
        provider { result in
            rows = result
            loading = false
        }
    }
}

// MARK: - 权限页面

struct PermissionPageView: View {
    @ObservedObject var model: SettingsModel
    @State private var snapshot = PermissionStatusSnapshot(
        captureGranted: false, inputGranted: false,
        sunshineRunning: false, sunshineStatusLine: "", probeOK: false)
    private let heartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                RichRow(symbol: "lock.shield",
                        title: "屏幕捕获（MoonRise）",
                        detail: snapshot.captureGranted
                            ? "已授予（全部实例共用该归属）"
                            : "未授予——允许系统弹窗，或在系统设置打开 MoonRise 开关") {
                    if !snapshot.captureGranted {
                        Button("请求屏幕捕获授权") { model.callbacks.requestCapturePermission?() }
                        Button("打开系统设置") { model.callbacks.openCaptureSystemSettings?() }
                    }
                }
                Divider()
                RichRow(symbol: "keyboard",
                        title: "输入控制（MoonRise）",
                        detail: snapshot.inputGranted
                            ? "已授予"
                            : "未授予——Moon 端键鼠控制需要；系统设置打开 MoonRise 开关") {
                    if !snapshot.inputGranted {
                        Button("请求输入控制授权") { model.callbacks.requestInputControlPermission?() }
                        Button("打开系统设置") { model.callbacks.openCaptureSystemSettings?() }
                    }
                }
                Divider()
                RichRow(symbol: "bolt.horizontal",
                        title: "Sunshine 进程",
                        detail: snapshot.sunshineStatusLine) {}
                Divider()
                RichRow(symbol: "video",
                        title: "编码器探测",
                        detail: snapshot.probeOK
                            ? "捕获就绪，VideoToolbox 硬件编码器就绪"
                            : "未通过（需要权限或重启）") {
                    if !snapshot.probeOK {
                        Button("重启 Sunshine") { model.callbacks.restartPrimarySunshine?() }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ContentSizeReporter { size in model.onContentSizeChanged?(size) })
        .onAppear { refresh() }
        .onReceive(heartbeat) { _ in refresh() }
    }

    private func refresh() {
        if let snapshot = model.permissionProvider?() {
            self.snapshot = snapshot
        }
    }

    private var guidance: String {
        if !snapshot.captureGranted || !snapshot.inputGranted {
            var steps = "权限对象是 MoonRise（Sunshine 以子进程运行，macOS 按责任进程向 MoonRise 收权限；给 sunshine 二进制授权无效）。"
            if !snapshot.captureGranted {
                steps += " ① 屏幕捕获：点「请求屏幕捕获授权」→ 弹窗点「允许」。"
            }
            if !snapshot.inputGranted {
                steps += " ② 输入控制：点「请求输入控制授权」→ 系统设置中打开 MoonRise 开关（Moon 端键鼠控制需要）。"
            }
            steps += " 完成后本页数秒内自动变绿，Sunshine 会自动重启。"
            return steps
        }
        if !snapshot.probeOK {
            return "权限已全部授予 ✓。Sunshine 需要重启以重跑编码器探测：点「重启 Sunshine」。（授权翻转时通常已自动完成）"
        }
        return "全部就绪 ✓：可在 Moon 端 Moonlight 全屏连接本机，验证扩展屏。"
    }
}
