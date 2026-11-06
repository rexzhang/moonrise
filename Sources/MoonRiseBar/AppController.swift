// AppController.swift — 菜单栏 App 主体：建屏、Sunshine 联动、菜单与状态。

import AppKit
import CoreGraphics
import ServiceManagement
import MoonRiseCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // MARK: - 状态

    fileprivate enum Phase {
        case starting
        case running(displayID: CGDirectDisplayID, spec: DisplaySpec, sunshine: String)
        case degraded(message: String)
    }

    private var config = AppConfig.load()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var virtualController: VirtualDisplayController?
    private var sunshineManager: SunshineManaging
    private var realized: RealizedDisplay?
    private var sunshineStatus = "待启动"
    private var phase: Phase = .starting
    private var busy = false
    private var watchdog: Timer?
    private var resolutionPanel: ResolutionPanelWindow?
    private var lastCapturePermission: Bool?
    private var restartedSunshineAfterGrant = false
    private var diagnosticsWindow: DiagnosticsWindow?
    private var permissionPanel: PermissionPanel?

    private var currentSpec: DisplaySpec {
        (try? config.display.spec.validated()) ?? .default
    }

    // MARK: - 生命周期

    override init() {
        if let binPath = ChildProcessSunshineManager.detectBinary() {
            sunshineManager = ChildProcessSunshineManager(
                binPath: binPath,
                confPath: Paths.expandTilde(config.sunshine.configPath),
                logURL: Paths.stateDirectory.appendingPathComponent("sunshine-child.log"),
                hideTrayIcon: config.sunshine.hideTrayIcon)
        } else {
            let brewPath = BrewServicesSunshineManager.detectBrew() ?? "/opt/homebrew/bin/brew"
            sunshineManager = BrewServicesSunshineManager(brewPath: brewPath)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshMenu()

        runBusy {
            do {
                let controller = try VirtualDisplayController()
                self.virtualController = controller
                self.registerReconfigurationCallback()
                // 权限引导：屏幕捕获或输入控制缺失时自动打开面板
                self.lastCapturePermission = CapturePermission.granted
                if !CapturePermission.granted || !CapturePermission.inputControlGranted {
                    DispatchQueue.main.async { self.showPermissionPanel() }
                    Log.info("屏幕捕获/输入控制权限缺失：已自动打开权限引导面板")
                }
                if self.config.display.keepHostScaling {
                    HostDisplayModeKeeper.snapshot()   // Moon 建屏前记录 host 显示模式基线
                }
                try self.reconcile()
                if self.config.display.keepHostScaling {
                    HostDisplayModeKeeper.restoreAll() // 拓扑变化后恢复 host 缩放
                }
                self.startWatchdog()
            } catch {
                self.degrade(error: error)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 生命周期即进程：退出即销毁（~0.4s，可接受）。
        // 注：进程终止期主 run loop 不再运转，CG 回调不会送达，无需反注册。
        try? virtualController?.teardown()
        if config.display.keepHostScaling {
            HostDisplayModeKeeper.restoreAll()   // Moon 销毁后恢复 host 缩放
        }
        try? sunshineManager.stop()
        reconfigUserData?.release()
        reconfigUserData = nil
    }

    // MARK: - 核心动作（后台执行）

    /// 建屏 + Sunshine 联动 + 状态落盘。在后台队列调用。
    private func reconcile() throws {
        guard let virtualController else {
            throw NSError(
                domain: "com.rexzhang.moonrise",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "虚拟屏控制器不可用"])
        }
        let spec = try currentSpec
        let display = try virtualController.realize(spec)
        realized = display
        Log.info("虚拟屏已建：id=\(display.displayID) \(spec.width)x\(spec.height)@\(spec.refreshRate)")

        let outcome = SunshineSync.sync(
            outputName: display.displayID,
            config: config,
            manager: sunshineManager)
        sunshineStatus = Self.sunshineStatusText(outcome)
        Log.info("Sunshine 联动：\(outcome)")

        phase = .running(displayID: display.displayID, spec: spec, sunshine: sunshineStatus)
        writeState()
    }

    private static func sunshineStatusText(_ outcome: SunshineSync.Outcome) -> String {
        switch outcome {
        case .synced, .started, .unchanged:
            return "已同步"
        case .notInstalled:
            return "未安装"
        case .missingConfig:
            return "待初始化"
        case .failed(let reason):
            return "失败：\(reason)"
        }
    }

    private func degrade(error: Error) {
        Log.error("启动失败：\(error.localizedDescription)")
        phase = .degraded(message: error.localizedDescription)
        writeState()
    }

    private func writeState() {
        let state: AppState
        switch phase {
        case .running(let displayID, let spec, let sunshine):
            state = AppState(
                displayID: displayID,
                spec: spec,
                sunshineOutputName: realized.map { String($0.displayID) },
                sunshineSyncStatus: sunshine)
        case .degraded(let message):
            state = AppState(lastError: message)
        case .starting:
            state = AppState()
        }
        state.write()
    }

    private func runBusy(_ work: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        DispatchQueue.main.async { self.refreshMenu() }
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async {
                self.busy = false
                self.refreshMenu()
            }
        }
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func refreshMenu() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(statusMenuItem())

        let actionsEnabled = !busy && phase.isRunning

        let restartItem = NSMenuItem(
            title: "重新开始虚拟屏",
            action: #selector(restartDisplay), keyEquivalent: "")
        restartItem.target = self
        restartItem.isEnabled = actionsEnabled
        menu.addItem(restartItem)

        let resolutionRoot = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
        let resolutionMenu = NSMenu()
        for preset in Self.presets {
            let item = NSMenuItem(
                title: "\(preset.width)×\(preset.height) @\(preset.refreshRate)Hz",
                action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(preset.width)x\(preset.height)@\(preset.refreshRate)"
            item.isEnabled = actionsEnabled
            let spec = currentSpec
            if preset.width == spec.width && preset.height == spec.height && preset.refreshRate == spec.refreshRate {
                item.state = .on
            }
            resolutionMenu.addItem(item)
        }
        resolutionMenu.addItem(.separator())
        let customItem = NSMenuItem(title: "自定义…", action: #selector(showCustomResolution), keyEquivalent: "")
        customItem.target = self
        customItem.isEnabled = actionsEnabled
        resolutionMenu.addItem(customItem)
        resolutionRoot.submenu = resolutionMenu
        menu.addItem(resolutionRoot)

        let keepScalingItem = NSMenuItem(title: "保持显示器缩放", action: #selector(toggleKeepHostScaling), keyEquivalent: "")
        keepScalingItem.target = self
        keepScalingItem.isEnabled = !busy
        keepScalingItem.state = config.display.keepHostScaling ? .on : .off
        menu.addItem(keepScalingItem)

        let sunshineRoot = NSMenuItem(title: "Sunshine", action: nil, keyEquivalent: "")
        let sunshineMenu = NSMenu()
        let runStateItem = NSMenuItem(title: "状态：\(sunshineManager.statusLine())", action: nil, keyEquivalent: "")
        runStateItem.isEnabled = false
        sunshineMenu.addItem(runStateItem)
        let audioItem = NSMenuItem(title: "禁用音频串流", action: #selector(toggleAudioStreaming), keyEquivalent: "")
        audioItem.target = self
        audioItem.isEnabled = !busy
        audioItem.state = config.sunshine.disableAudioStreaming ? .on : .off
        sunshineMenu.addItem(audioItem)
        let syncItem = NSMenuItem(title: "重新同步 output_name", action: #selector(syncSunshine), keyEquivalent: "")
        syncItem.target = self
        syncItem.isEnabled = actionsEnabled
        sunshineMenu.addItem(syncItem)
        let restartSunshineItem = NSMenuItem(title: "重启 Sunshine", action: #selector(restartSunshine), keyEquivalent: "")
        restartSunshineItem.target = self
        restartSunshineItem.isEnabled = actionsEnabled
        sunshineMenu.addItem(restartSunshineItem)
        let webUIItem = NSMenuItem(title: "打开 Web UI", action: #selector(openWebUI), keyEquivalent: "")
        webUIItem.target = self
        webUIItem.isEnabled = !busy
        sunshineMenu.addItem(webUIItem)
        sunshineRoot.submenu = sunshineMenu
        menu.addItem(sunshineRoot)

        let permissionItem = NSMenuItem(title: "权限引导…", action: #selector(showPermissionPanel), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.isEnabled = !busy
        menu.addItem(permissionItem)

        let diagnosticsItem = NSMenuItem(title: "诊断…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        diagnosticsItem.isEnabled = !busy
        menu.addItem(diagnosticsItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.isEnabled = !busy
        loginItem.state = loginItemStatus
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 MoonRise", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = !busy
        menu.addItem(quitItem)

        updateIcon()
    }

    static let presets: [DisplaySpec] = [
        DisplaySpec(name: "Moon", width: 2560, height: 1600, refreshRate: 60),
        DisplaySpec(name: "Moon", width: 1920, height: 1200, refreshRate: 60),
        DisplaySpec(name: "Moon", width: 2560, height: 1440, refreshRate: 60),
        DisplaySpec(name: "Moon", width: 1920, height: 1080, refreshRate: 60)
    ]

    private func statusMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "启动中…", action: nil, keyEquivalent: "")
        item.isEnabled = false
        switch phase {
        case .starting:
            item.title = "启动中…"
        case .running(let displayID, let spec, let sunshine):
            item.title = "\(spec.width)×\(spec.height)@\(spec.refreshRate) · id \(displayID) · Sunshine \(sunshine)"
        case .degraded(let message):
            item.title = "错误：\(message)"
        }
        return item
    }

    private var loginItemStatus: NSControl.StateValue {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled ? .on : .off
        }
        return .off
    }

    private func updateIcon() {
        let image: NSImage
        switch phase {
        case .starting, .running:
            image = BrandGlyph.normal()
        case .degraded:
            image = BrandGlyph.problem()
        }
        statusItem.button?.image = image
    }

    // MARK: - 菜单动作

    @objc private func restartDisplay() {
        runBusy {
            do {
                try self.reconcile()
            } catch {
                self.degrade(error: error)
            }
        }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String else { return }
        let parts = payload.split(separator: "x")
        guard parts.count == 2 else { return }
        let sizeParts = parts[1].split(separator: "@")
        guard sizeParts.count == 2,
              let width = Int(parts[0]), let height = Int(sizeParts[0]), let rate = Int(sizeParts[1]) else {
            return
        }
        applyResolution(width: width, height: height, refreshRate: rate)
    }

    @objc private func showCustomResolution() {
        if resolutionPanel == nil {
            resolutionPanel = ResolutionPanelWindow()
        }
        resolutionPanel?.show(initialSpec: currentSpec) { [weak self] width, height, rate in
            self?.applyResolution(width: width, height: height, refreshRate: rate)
        }
    }

    private func applyResolution(width: Int, height: Int, refreshRate: Int) {
        let newSpec = DisplaySpec(
            name: config.display.name, width: width, height: height, refreshRate: refreshRate)
        guard (try? newSpec.validated()) != nil else {
            showInfoAlert("无效分辨率", text: "尺寸需在 64–16384px、刷新率 1–240Hz")
            return
        }
        config.display.width = width
        config.display.height = height
        config.display.refreshRate = refreshRate
        try? config.save()

        runBusy {
            do {
                try self.reconcile()
            } catch {
                self.degrade(error: error)
            }
        }
    }

    @objc private func toggleAudioStreaming() {
        config.sunshine.disableAudioStreaming.toggle()
        try? config.save()
        syncSunshine()  // 应用到 sunshine.conf；值变化会自动重启 Sunshine
    }

    @objc private func syncSunshine() {
        runBusy {
            guard let display = self.realized else { return }
            let outcome = SunshineSync.sync(
                outputName: display.displayID,
                config: self.config,
                manager: self.sunshineManager)
            self.sunshineStatus = Self.sunshineStatusText(outcome)
            if case .running(let displayID, let spec, _) = self.phase {
                self.phase = .running(displayID: displayID, spec: spec, sunshine: self.sunshineStatus)
            }
            self.writeState()
        }
    }

    @objc private func restartSunshine() {
        runBusy {
            do {
                try self.sunshineManager.restart()
                self.sunshineStatus = "已重启"
            } catch {
                self.sunshineStatus = "重启失败"
                Log.error("重启 Sunshine 失败：\(error.localizedDescription)")
            }
            if case .running(let displayID, let spec, _) = self.phase {
                self.phase = .running(displayID: displayID, spec: spec, sunshine: self.sunshineStatus)
            }
            self.writeState()
        }
    }

    @objc private func openWebUI() {
        NSWorkspace.shared.open(URL(string: "https://localhost:47990")!)
    }

    @objc private func showPermissionPanel() {
        if permissionPanel == nil {
            permissionPanel = PermissionPanel()
        }
        permissionPanel?.present(context: PermissionPanel.Context(
            manager: sunshineManager,
            sunshineLogPath: Paths.stateDirectory.appendingPathComponent("sunshine-child.log").path,
            restartSunshine: { [weak self] in
                DispatchQueue.global(qos: .userInitiated).async {
                    try? self?.sunshineManager.restart()
                }
            }))
    }

    @objc private func showDiagnostics() {
        if diagnosticsWindow == nil {
            diagnosticsWindow = DiagnosticsWindow()
        }
        diagnosticsWindow?.present(context: DiagnosticsWindow.DiagnosticsContext(
            realized: realized,
            liveDisplayIDs: liveIDs(),
            sunshineStatus: sunshineStatus,
            manager: sunshineManager,
            sunshineConfigPath: config.sunshine.configPath))
    }

    @objc private func toggleKeepHostScaling() {
        config.display.keepHostScaling.toggle()
        try? config.save()
        refreshMenu()
    }

    @objc private func toggleLoginItem() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {
                showInfoAlert("开机自启设置失败", text: "\(error.localizedDescription)\n\n从 swift run 直接启动无法注册登录项；请先用 scripts/install-app.sh 安装为 App。")
            }
            refreshMenu()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 显示器重配置回调 + 看门狗

    private var reconfigUserData: Unmanaged<AppController>?

    private func registerReconfigurationCallback() {
        let userData = Unmanaged.passRetained(self)
        reconfigUserData = userData
        CGDisplayRegisterReconfigurationCallback(
            { _, flags, userInfo in
                guard let userInfo else { return }
                let controller = Unmanaged<AppController>.fromOpaque(userInfo).takeUnretainedValue()
                if flags.contains(.removeFlag) || flags.contains(.disabledFlag) {
                    controller.displayLostExternally()
                }
            },
            userData.toOpaque())
    }

    /// 我们持有屏被外部移除（理论不应发生；兜底）→ 主线程重建
    fileprivate func displayLostExternally() {
        guard !busy, let display = realized, liveIDs().contains(display.displayID) == false else { return }
        runBusy {
            do {
                try self.reconcile()
            } catch {
                self.degrade(error: error)
            }
        }
    }

    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !self.busy else { return }
            if let display = self.realized,
               self.liveIDs().contains(display.displayID) == false {
                Log.info("看门狗：虚拟屏消失，重建")
                self.displayLostExternally()
            }
            // managed 模式：Sunshine 孤儿/异常退出后兜底拉起
            if self.config.sunshine.restartPolicy == .managed,
               self.sunshineManager.statusLine() == "未运行" {
                Log.info("看门狗：Sunshine 未运行，重新拉起")
                self.runBusy {
                    try? self.sunshineManager.start()
                }
            }
            // 屏幕捕获授权完成 → 重启一次 Sunshine（启动期编码器探测需要权限）
            let granted = CapturePermission.granted
            if !self.restartedSunshineAfterGrant,
               self.lastCapturePermission == false, granted {
                self.restartedSunshineAfterGrant = true
                self.lastCapturePermission = granted
                Log.info("屏幕捕获权限已授予，重启 Sunshine 重跑编码器探测")
                self.runBusy {
                    try? self.sunshineManager.restart()
                }
            }
        }
    }

    private func liveIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // MARK: - 提示

    private func showInfoAlert(_ title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

extension AppController.Phase {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
