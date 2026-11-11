// ScreenManagerWindow.swift — 扩展屏幕管理（W1，SwiftUI）：信息列表 + 行内控件。
// 菜单栏「扩展屏幕管理…」打开；每屏卡片：状态胶囊 + IP:端口 + 启用/重启/Web UI/配对/修改/删除。

import AppKit
import SwiftUI
import MoonRiseCore

/// 每屏行内动作与错误反馈的接线（AppController 组装）。
struct ScreenCallbacks {
    var toggleEnabled: ((DisplayConfig) -> Void)?
    var restartSlot: ((UUID) -> Void)?
    var openWebUI: ((Int) -> Void)?
    var openPairing: ((DisplayConfig) -> Void)?
    var openEdit: ((DisplayConfig) -> Void)?
    var deleteSlot: ((DisplayConfig) -> Void)?
    var openAdd: (() -> Void)?
    var setKeepHostScaling: ((Bool) -> Void)?
}

/// W1 的 SwiftUI 状态模型（@Published 一律主线程更新）。
final class ScreenCenterModel: ObservableObject {
    @Published var displays: [DisplayConfig] = []
    @Published var summaries: [AppController.ScreenSummary] = []
    @Published var keepHostScaling = true
    @Published var errors: [UUID: String] = [:]
    var callbacks = ScreenCallbacks()
    /// 内容高度变化回调（实测，驱动窗口高度；宽度为设计定宽 760）。
    var onContentSizeChanged: ((CGSize) -> Void)?

    func refresh(displays: [DisplayConfig], summaries: [AppController.ScreenSummary], keepHostScaling: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.displays = displays
            self?.summaries = summaries
            self?.keepHostScaling = keepHostScaling
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

/// W1 宿主 + 窗口复用管理：不同屏允许并行窗口；同屏复用已有窗口并置前。
final class ScreenWindowController {
    static let shared = ScreenWindowController()
    let model = ScreenCenterModel()
    let listWindow: NSWindow
    private var editWindows: [UUID: NSWindow] = [:]
    private var pairingWindows: [UUID: NSWindow] = [:]

    private var observers: [NSObjectProtocol] = []

    init() {
        // 项目 UI 标准：窗口尺寸变化（内容驱动）后自动居中。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  let id = window.identifier?.rawValue,
                  id.hasPrefix("moonrise.") else { return }
            centerOnMainScreen(window)
        })
        listWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        listWindow.title = "扩展屏幕管理"
        listWindow.identifier = NSUserInterfaceItemIdentifier("moonrise.list")
        listWindow.isReleasedWhenClosed = false
        listWindow.backgroundColor = NSColor.windowBackgroundColor
        let listHosting = NSHostingController(rootView: ScreenManagerView(model: model))
        listHosting.sizingOptions = []
        // 用 contentView 挂载（不用 contentViewController——后者会让窗口采用
        // hosting 的 preferredContentSize，sizingOptions 为空时是 0×28，窗口塌缩）
        listWindow.contentView = listHosting.view
        model.onContentSizeChanged = { [weak self] contentSize in
            self?.setWindowSizeAndCenter(contentSize)
        }
        // 内容驱动的尺寸变化 → 自动居中（窗口不可手动调整，无争抢）
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: listWindow, queue: .main
        ) { [weak self] _ in
            self?.centerListWindow()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 窗口尺寸 = 实测内容尺寸（+padding/chrome），位置居中（钉主屏可视区）。
    func setWindowSizeAndCenter(_ contentSize: CGSize) {
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width >= 0, contentSize.height >= 0 else { return }
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1055)
        let targetHeight = min(max(contentSize.height + 49, 280), max(280, visible.height - 24))
        let targetWidth = min(max(contentSize.width + 32, 420), max(420, visible.width - 24))
        var frame = listWindow.frame
        frame.size.width = targetWidth
        frame.size.height = targetHeight
        frame.origin.x = visible.midX - targetWidth / 2
        frame.origin.y = visible.midY - targetHeight / 2
        listWindow.setFrame(frame, display: true, animate: false)
    }

    private func centerListWindow() {
        centerOnMainScreen(listWindow)
    }

    /// 窗口高度 = 实测内容高度（+28 标题栏），钳制后设框并自动居中（钉主屏）。
    func setWindowSize(_ window: NSWindow, contentHeight: CGFloat, minWidth: CGFloat) {
        guard window.isVisible, contentHeight.isFinite, contentHeight >= 0 else { return }
        let visible = primaryVisibleFrame()
        let target = min(max(contentHeight + 28, 280), max(280, visible.height - 24))
        var frame = window.frame
        frame.size.width = max(frame.width, minWidth)
        guard abs(frame.height - target) > 1 || frame.origin != centeredOrigin(window: frame.size.width) else { return }
        frame.origin.x = visible.midX - frame.size.width / 2
        frame.origin.y = visible.midY - target / 2
        frame.size.height = target
        window.setFrame(frame, display: true, animate: false)
    }

    private func centeredOrigin(window width: CGFloat) -> NSPoint? { nil }

    func showList() {
        listWindow.center()   // 项目 UI 标准：窗口自动居中
        listWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 修改窗口（复用置前）。onApply 的第二参为就地报错回调：非 nil = 失败，窗口保持。
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
                    if let errorMessage {
                        reportError(errorMessage)
                    } else {
                        close()
                    }
                }
            },
            onClose: close)
        editView.onContentHeight = { [weak self, weak window] contentHeight in
            guard let self, let window else { return }
            self.setWindowSize(window, contentHeight: contentHeight, minWidth: 450)
        }
        window.contentViewController = NSHostingController(rootView: editView)
        editWindows[display.id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
                    if let errorMessage {
                        reportError(errorMessage)
                    } else {
                        close()
                    }
                }
            },
            onClose: close)
        addView.onContentHeight = { [weak self, weak window] contentHeight in
            guard let self, let window else { return }
            self.setWindowSize(window, contentHeight: contentHeight, minWidth: 450)
        }
        window.contentViewController = NSHostingController(rootView: addView)
        addWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            webPort: webPort,
            isPrimary: display.sunshinePort == nil,
            onClose: { [weak window, weak self] in
                window?.close()
                self?.pairingWindows[display.id] = nil
            })
        pairingView.onContentHeight = { [weak self, weak window] contentHeight in
            guard let self, let window else { return }
            self.setWindowSize(window, contentHeight: contentHeight, minWidth: 350)
        }
        window.contentViewController = NSHostingController(rootView: pairingView)
        pairingWindows[display.id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

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

// MARK: - 列表视图

struct ScreenManagerView: View {
    @ObservedObject var model: ScreenCenterModel

    var body: some View {
        VStack(spacing: 0) {
            scrollContent
            Divider()
            footer
        }
        .frame(minWidth: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var scrollContent: some View {
        ScrollView {
            cardStack
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var cardStack: some View {
        VStack(spacing: 12) {
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
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ListContentSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(ListContentSizeKey.self) { contentSize in
            model.onContentSizeChanged?(contentSize)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("还没有扩展屏幕")
                .font(.headline)
            Text("点下方「添加屏幕…」创建第一块屏：可选 MacBook / iPad 等预设，或自定义规格。创建后在 Moonlight 手动添加对应的 IP:端口 即可连接。")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        HStack {
            Button("添加屏幕…") { model.callbacks.openAdd?() }
                .buttonStyle(.borderedProminent)
            Toggle("保持显示器缩放", isOn: Binding(
                get: { model.keepHostScaling },
                set: { newValue in
                    model.keepHostScaling = newValue
                    model.callbacks.setKeepHostScaling?(newValue)
                }))
                .toggleStyle(.switch)
            Spacer()
            Text("状态 1s 自动刷新")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
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
            ipLine
            actionRow
            if let error {
                Text("✗ \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .frame(width: 700, alignment: .leading)   // 设计定宽：动作行与 IP 行的舒适宽度
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .opacity(display.enabled ? 1 : 0.62)
    }

    private var header: some View {
        HStack {
            statePill
            Text(display.name).fontWeight(.semibold)
            Text(portText).foregroundColor(.secondary).font(.caption)
            Spacer()
            Text(summary?.syncStatus ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var ipLine: some View {
        Text("IP \(AppController.lanAddress() ?? "localhost"):\(portValue)")
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .onTapGesture { AppController.copyToPasteboard(hostText) }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Toggle("启用", isOn: enabledBinding)
                .toggleStyle(.switch)
                .font(.caption)
            Button("重启该屏") { callbacks.restartSlot?(display.id) }
                .disabled(!display.enabled)
            Button("Web UI") { callbacks.openWebUI?(portValue + 1) }
                .disabled(!display.enabled)
            Button("配对…") { callbacks.openPairing?(display) }
                .disabled(!display.enabled)
            Button("修改…") { callbacks.openEdit?(display) }
            Button("删除") { callbacks.deleteSlot?(display) }
                .foregroundColor(.red)
                .disabled(display.sunshinePort == nil)
        }
        .font(.caption)
    }

    private var portValue: Int {
        display.sunshinePort ?? 47989
    }

    private var portText: String {
        display.sunshinePort.map { "端口 \($0)" } ?? "主配置 47989"
    }

    private var hostText: String {
        "\(AppController.lanAddress() ?? "localhost"):\(portValue)"
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { display.enabled },
            set: { newValue in
                guard newValue != display.enabled else { return }
                var updated = display
                updated.enabled = newValue
                callbacks.toggleEnabled?(updated)
            })
    }

    /// 状态胶囊（方案 A）。
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
