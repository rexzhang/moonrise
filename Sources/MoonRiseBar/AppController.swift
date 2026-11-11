// AppController.swift — 菜单栏 App 主体：多屏编排接线、状态显示菜单、守护。
// 菜单只做状态显示（D7）；全部管理操作收敛于统一管理窗口。

import AppKit
import CoreGraphics
import ServiceManagement
import MoonRiseCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // MARK: - 状态

    fileprivate enum Phase {
        case starting
        case running
        case degraded(message: String)
    }

    /// 每屏摘要（菜单状态行 / 诊断 / 管理窗口共用）
    struct ScreenSummary {
        let slotID: UUID
        let name: String
        let slotNumber: Int
        let displayID: CGDirectDisplayID?
        let spec: DisplaySpec
        let enabled: Bool
        let port: Int?
        let state: ScreenState
        let syncStatus: String
        let instanceStatus: String
    }

    private var config = AppConfig.load()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var virtualController: VirtualDisplayController?
    private var sunshineManager: SunshineManaging
    private var registry: SunshineInstanceRegistry?
    private var orchestrator: DisplayOrchestrator?
    private var sunshineStatus = "待启动"
    private var phase: Phase = .starting
    private var busy = false
    private var watchdog: Timer?
    private var lastCapturePermission: Bool?
    private var restartedSunshineAfterGrant = false
    private var diagnosticsWindow: DiagnosticsWindow?
    private var permissionPanel: PermissionPanel?

    // MARK: - 生命周期

    override init() {
        if let binPath = BrewServicesSunshineManager.detectBinary() {
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
                let registry = SunshineInstanceRegistry(
                    sourceBinaryPath: BrewServicesSunshineManager.detectBinary() ?? "",
                    hideTrayIcon: self.config.sunshine.hideTrayIcon)
                let orchestrator = DisplayOrchestrator(
                    controller: controller,
                    registry: registry,
                    primaryManager: self.sunshineManager,
                    configProvider: { [weak self] in self?.config ?? AppConfig() },
                    liveDisplayIDs: { [weak self] in self?.liveIDs() ?? [] })
                orchestrator.streamMonitor.onStreamingChanged = { [weak self] _, _ in
                    DispatchQueue.main.async {
                        self?.refreshMenu()
                        self?.writeState()
                    }
                }
                orchestrator.streamMonitor.start()
                self.virtualController = controller
                self.registry = registry
                self.orchestrator = orchestrator

                self.registerReconfigurationCallback()
                // 权限引导：屏幕捕获或输入控制缺失时自动打开面板
                self.lastCapturePermission = CapturePermission.granted
                if !CapturePermission.granted || !CapturePermission.inputControlGranted {
                    DispatchQueue.main.async { self.showPermissionPanel() }
                    Log.info("屏幕捕获/输入控制权限缺失：已自动打开权限引导面板")
                }
                if self.config.keepHostScaling {
                    HostDisplayModeKeeper.snapshot()   // Moon 建屏前记录 host 显示模式基线
                }
                try orchestrator.reconcile()
                if self.config.keepHostScaling {
                    HostDisplayModeKeeper.restoreAll() // 拓扑变化后恢复 host 缩放
                }
                self.phase = .running
                self.cleanupOrphanInstanceDirectories()
                self.startWatchdog()
            } catch {
                self.degrade(error: error)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 生命周期即进程：退出即销毁（可接受）。
        orchestrator?.shutdown()
        if config.keepHostScaling {
            HostDisplayModeKeeper.restoreAll()   // Moon 销毁后恢复 host 缩放
        }
        // 扩展屏实例逐个停（串行），再停首屏主实例
        for display in config.displays where display.sunshinePort != nil {
            if let manager = registry?.managerIfExists(for: display.id) {
                try? manager.stop()
            }
        }
        try? sunshineManager.stop()
        reconfigUserData?.release()
        reconfigUserData = nil
    }

    // MARK: - 摘要

    private func screenSummaries() -> [ScreenSummary] {
        let live = Set(liveIDs())
        return config.displays
            .sorted { $0.slotNumber < $1.slotNumber }
            .map { display in
                let realizedDisplay = orchestrator?.realized[display.id]
                let displayID = realizedDisplay?.displayID
                let streaming = display.enabled
                    && displayID != nil
                    && (orchestrator?.streamMonitor.isStreaming(slotID: display.id) ?? false)
                let instanceRunning: Bool
                let instanceStatus: String
                if display.sunshinePort == nil {
                    instanceStatus = sunshineManager.statusLine()
                    instanceRunning = instanceStatus != "未运行"
                } else if let manager = registry?.managerIfExists(for: display.id) {
                    instanceStatus = manager.statusLine()
                    instanceRunning = instanceStatus != "未运行"
                } else {
                    instanceStatus = "未创建"
                    instanceRunning = false
                }
                let state = ScreenState.resolve(
                    enabled: display.enabled,
                    displayID: displayID,
                    instanceRunning: instanceRunning,
                    streaming: streaming)
                return ScreenSummary(
                    slotID: display.id,
                    name: display.name,
                    slotNumber: display.slotNumber,
                    displayID: displayID,
                    spec: display.spec,
                    enabled: display.enabled,
                    port: display.sunshinePort,
                    state: state,
                    syncStatus: orchestrator?.syncStatus[display.id] ?? "",
                    instanceStatus: instanceStatus)
            }
    }

    // MARK: - 核心动作（后台执行）

    /// 全量收敛（diff；看门狗/回调/重新同步共用）
    private func reconcileNow() throws {
        guard let orchestrator else {
            throw NSError(domain: "com.rexzhang.moonrise", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "编排器不可用"])
        }
        try orchestrator.reconcile()
        phase = .running
        writeState()
    }

    private func degrade(error: Error) {
        Log.error("启动失败：\(error.localizedDescription)")
        phase = .degraded(message: error.localizedDescription)
        writeState()
    }

    private func writeState() {
        refreshScreenModel()
        let summaries = screenSummaries()
        let screens = summaries.map { summary in
            ScreenRuntimeState(
                slotID: summary.slotID,
                name: summary.name,
                slotNumber: summary.slotNumber,
                displayID: summary.displayID,
                width: summary.spec.width,
                height: summary.spec.height,
                refreshRate: summary.spec.refreshRate,
                hiDPI: summary.spec.hiDPI,
                enabled: summary.enabled,
                streaming: summary.state == .streaming,
                sunshinePort: summary.port,
                syncStatus: summary.syncStatus)
        }
        let state: AppState
        if case .degraded(let message) = phase {
            state = AppState(screens: screens, lastError: message)
        } else {
            state = AppState(screens: screens)
        }
        state.write()
    }

    private func runBusy(_ work: @escaping () -> Void, completion: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        DispatchQueue.main.async { self.refreshMenu() }
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async {
                self.busy = false
                self.refreshMenu()
                self.writeState()
                completion?()
            }
        }
    }

    // MARK: - 菜单（只做状态显示，D7）

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func refreshMenu() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(statusMenuItem())

        let summaries = screenSummaries()
        let enabledCount = summaries.filter(\.enabled).count
        let streamingCount = summaries.filter { $0.state == .streaming }.count
        let instancesTotal = summaries.filter { $0.enabled }.count
        let instancesRunning = summaries.filter { $0.enabled && $0.instanceStatus != "未运行" }.count

        for summary in summaries {
            let item = NSMenuItem(
                title: "\(summary.state.symbol) \(summary.name) · \(summary.state.label)",
                action: #selector(openScreenManagerMenuItem(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = summary.slotID.uuidString
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let manageItem = NSMenuItem(title: "扩展屏幕管理…", action: #selector(openScreenManager(_:)), keyEquivalent: "")
        manageItem.target = self
        manageItem.isEnabled = !busy
        menu.addItem(manageItem)

        let sunshineRoot = NSMenuItem(title: "Sunshine", action: nil, keyEquivalent: "")
        let sunshineMenu = NSMenu()
        let runStateItem = NSMenuItem(title: "主实例：\(sunshineManager.statusLine())", action: nil, keyEquivalent: "")
        runStateItem.isEnabled = false
        sunshineMenu.addItem(runStateItem)
        let audioItem = NSMenuItem(title: "禁用音频串流", action: #selector(toggleAudioStreaming), keyEquivalent: "")
        audioItem.target = self
        audioItem.isEnabled = !busy
        audioItem.state = config.sunshine.disableAudioStreaming ? .on : .off
        sunshineMenu.addItem(audioItem)
        let restartAllItem = NSMenuItem(title: "重启全部实例", action: #selector(restartAllInstances), keyEquivalent: "")
        restartAllItem.target = self
        restartAllItem.isEnabled = !busy && instancesRunning > 0
        sunshineMenu.addItem(restartAllItem)
        let syncItem = NSMenuItem(title: "重新同步", action: #selector(resyncAll), keyEquivalent: "")
        syncItem.target = self
        syncItem.isEnabled = !busy
        sunshineMenu.addItem(syncItem)
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

    private func statusMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "启动中…", action: nil, keyEquivalent: "")
        item.isEnabled = false
        switch phase {
        case .starting:
            item.title = "启动中…"
        case .running:
            let summaries = screenSummaries()
            let enabledCount = summaries.filter(\.enabled).count
            let streamingCount = summaries.filter { $0.state == .streaming }.count
            let instancesTotal = summaries.filter { $0.enabled }.count
            let instancesRunning = summaries.filter { $0.enabled && $0.instanceStatus != "未运行" }.count
            item.title = "\(enabledCount) 屏 · 串流 \(streamingCount) · 实例 \(instancesRunning)/\(instancesTotal)"
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

    @objc private func openScreenManagerMenuItem(_ sender: NSMenuItem) {
        showScreenManager()
    }

    @objc private func openScreenManager(_ sender: NSMenuItem) {
        showScreenManager()
    }

    @objc private func resyncAll() {
        runBusy {
            do {
                try self.reconcileNow()
            } catch {
                Log.error("重新同步失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func restartAllInstances() {
        runBusy {
            try? self.sunshineManager.restart()
            for display in self.config.displays where display.enabled && display.sunshinePort != nil {
                if let manager = try? self.registry?.manager(for: display) {
                    try? manager.restart()
                }
            }
            self.sunshineStatus = "已重启"
        }
    }

    @objc private func toggleAudioStreaming() {
        config.sunshine.disableAudioStreaming.toggle()
        try? config.save()
        resyncAll()   // 值变才重启受影响实例（精确到实例）
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
        let live = liveIDs()
        let screens = screenSummaries().map { summary in
            DiagnosticsWindow.ScreenDiagnostics(
                name: summary.name,
                slotID: summary.slotID,
                displayID: summary.displayID,
                isLive: summary.displayID.map { live.contains($0) } ?? false,
                spec: summary.spec,
                port: summary.port,
                enabled: summary.enabled,
                syncStatus: summary.syncStatus)
        }
        diagnosticsWindow?.present(context: DiagnosticsWindow.DiagnosticsContext(
            screens: screens,
            sunshineStatus: sunshineStatus,
            manager: sunshineManager))
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

    // MARK: - 扩展屏幕管理（SwiftUI 三窗：列表 / 修改 / 配对）

    private func showScreenManager() {
        wireScreenCallbacks()
        refreshScreenModel()
        ScreenWindowController.shared.showList()
    }

    private func refreshScreenModel() {
        let displays = config.displays
        let summaries = screenSummaries()
        let keep = config.keepHostScaling
        DispatchQueue.main.async {
            ScreenWindowController.shared.model.refresh(
                displays: displays, summaries: summaries, keepHostScaling: keep)
        }
    }

    private func wireScreenCallbacks() {
        ScreenWindowController.shared.model.callbacks = ScreenCallbacks(
            toggleEnabled: { [weak self] display in self?.setEnabled(display) },
            restartSlot: { [weak self] slotID in self?.restartSlot(slotID: slotID) },
            openWebUI: { port in
                if let url = URL(string: "https://localhost:\(port)") {
                    NSWorkspace.shared.open(url)
                }
            },
            openPairing: { [weak self] display in
                ScreenWindowController.shared.openPairing(display: display)
            },
            openEdit: { [weak self] display in self?.openEdit(display) },
            deleteSlot: { [weak self] display in self?.deleteSlot(display) },
            openAdd: { [weak self] in self?.openAddScreen() },
            setKeepHostScaling: { [weak self] enabled in
                self?.config.keepHostScaling = enabled
                try? self?.config.save()
            })
    }

    private func openEdit(_ display: DisplayConfig) {
        let streaming = ScreenWindowController.shared.model.summary(for: display.id)?.state == .streaming
        ScreenWindowController.shared.openEdit(
            display: display,
            streaming: streaming,
            others: config.displays,
            onApply: { [weak self] newDisplay, reportError in
                self?.applySlotEdit(newDisplay, reportError: reportError)
            })
    }

    private func openAddScreen() {
        let autoName = Self.nextAutoName(used: Set(config.displays.map(\.name)))
        ScreenWindowController.shared.openAdd(
            initialName: autoName,
            others: config.displays,
            onApply: { [weak self] candidate, reportError in
                self?.addScreen(candidate, reportError: reportError)
            })
    }

    // MARK: - 逐屏动作（W1/W2 即时应用；失败就地报错在卡片/窗口，无弹窗）

    private func restartSlot(slotID: UUID) {
        runBusy {
            guard let display = self.config.displays.first(where: { $0.id == slotID }) else { return }
            if display.sunshinePort == nil {
                try? self.sunshineManager.restart()
            } else if let manager = try? self.registry?.manager(for: display) {
                try? manager.restart()
            }
        }
    }

    private func setEnabled(_ display: DisplayConfig) {
        runBusy {
            do {
                try ScreenChangeValidator.validate(display, others: self.config.displays)
                guard let idx = self.config.displays.firstIndex(where: { $0.id == display.id }) else { return }
                self.config.displays[idx] = display
                try? self.config.save()
                try self.orchestrator?.setEnabled(display)
            } catch {
                Log.error("启用/停用失败：\(error.localizedDescription)")
                ScreenWindowController.shared.model.reportError(display.id, error.localizedDescription)
            }
        }
    }

    private func deleteSlot(_ display: DisplayConfig) {
        runBusy {
            do {
                try self.orchestrator?.remove(slotID: display.id)
                self.config.displays.removeAll { $0.id == display.id }
                try? self.config.save()
                try? FileManager.default.removeItem(at: InstanceConf.directory(for: display.id))
                ScreenWindowController.shared.closeEdit(slotID: display.id)
            } catch {
                Log.error("删除失败：\(error.localizedDescription)")
                ScreenWindowController.shared.model.reportError(display.id, error.localizedDescription)
            }
        }
    }

    private func applySlotEdit(_ newDisplay: DisplayConfig, reportError: @escaping (String?) -> Void) {
        runBusy {
            do {
                try ScreenChangeValidator.validate(newDisplay, others: self.config.displays)
                guard let idx = self.config.displays.firstIndex(where: { $0.id == newDisplay.id }) else {
                    reportError("屏幕不存在")
                    return
                }
                let before = self.config.displays[idx]
                self.config.displays[idx] = newDisplay
                try? self.config.save()
                if before.enabled != newDisplay.enabled {
                    try self.orchestrator?.setEnabled(newDisplay)
                } else if newDisplay.enabled {
                    try self.orchestrator?.rebuild(newDisplay)
                }
                // 停用屏：只写配置，启用时按新规格生效
            } catch {
                Log.error("应用修改失败：\(error.localizedDescription)")
                reportError(error.localizedDescription)
            }
        }
    }

    /// 添加屏幕（W2 添加模式应用）：校验 → 分配编号/命名/端口 → 建屏起实例。
    private func addScreen(_ candidate: DisplayConfig, reportError: @escaping (String?) -> Void) {
        runBusy {
            do {
                try ScreenChangeValidator.validate(candidate, others: self.config.displays)
                guard let orchestrator = self.orchestrator else { return }
                var display = candidate
                display.slotNumber = (self.config.displays.map(\.slotNumber).max() ?? 0) + 1
                guard let port = self.allocateInstancePort() else {
                    throw NSError(
                        domain: "com.rexzhang.moonrise",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "可用端口段已用尽，无法新增屏幕"])
                }
                display.sunshinePort = port
                self.config.displays.append(display)
                try? self.config.save()
                try orchestrator.create(display)
                Log.info("新增屏幕：\(display.name) \(display.width)x\(display.height) 端口 \(port)")
                reportError(nil)   // 成功：关闭添加窗口
            } catch {
                Log.error("新增屏幕失败：\(error.localizedDescription)")
                reportError(error.localizedDescription)
            }
        }
    }

    /// 清理孤儿实例目录（配置中已不存在的槽位残留，历次配置变更/UUID 期遗留）。
    private func cleanupOrphanInstanceDirectories() {
        let root = Paths.sunshineInstancesDirectory
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let active = Set(config.displays.map { $0.id.uuidString })
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where entry.hasSuffix(".uuid") || UUID(uuidString: entry) != nil {
            if !active.contains(entry) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(entry))
                Log.info("清理孤儿实例目录：\(entry)")
            }
        }
    }

    /// 自动命名：Moon N 跳过已用名的最小 N
    static func nextAutoName(used: Set<String>) -> String {
        var n = 1
        while used.contains("Moon \(n)") {
            n += 1
        }
        return "Moon \(n)"
    }

    /// 端口分配：步进 100 + 占用探测（D3）；被占则继续步进
    private func allocateInstancePort() -> Int? {
        var taken = Set(config.displays.compactMap(\.sunshinePort))
        while let port = InstanceConf.PortAllocator.nextFree(taken: taken) {
            if InstanceConf.isBindable(port) {
                return port
            }
            taken.insert(port)
        }
        return nil
    }

    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        var ptr = ifaddr
        while let current = ptr {
            let ifa = current.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1" {
                        if String(cString: ifa.ifa_name).hasPrefix("en") {
                            return ip   // 优先物理网卡
                        }
                        fallback = fallback ?? ip
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return fallback
    }

    /// 剪贴板写入（W1 IP 复制 / W3 凭据复制共用）。
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
                    // 差异收敛自然定位丢失槽位并只重建该槽（D10：停用屏不复活）
                    controller.reconcileExternally()
                }
                // 拓扑落定即恢复 host 缩放（低 DPI 闪烁窗口 ~0.5s → ~50ms）
                if flags.contains(.addFlag) || flags.contains(.enabledFlag)
                    || flags.contains(.removeFlag) || flags.contains(.setMainFlag)
                    || flags.contains(.movedFlag) {
                    controller.scheduleHostScalingRestore()
                }
            },
            userData.toOpaque())
    }

    private var hostScalingRestorePending = false

    /// 拓扑落定后调度一次 host 缩放恢复（去抖合并；keepHostScaling 门控）
    fileprivate func scheduleHostScalingRestore() {
        guard config.keepHostScaling, !hostScalingRestorePending else { return }
        hostScalingRestorePending = true
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.hostScalingRestorePending else { return }
            HostDisplayModeKeeper.restoreAll()
            self.hostScalingRestorePending = false
        }
    }

    /// 外部拓扑变化 → 差异收敛（丢失槽只重建该槽；停用屏不复活）
    fileprivate func reconcileExternally() {
        guard !busy, orchestrator != nil else { return }
        runBusy {
            do {
                try self.reconcileNow()
            } catch {
                Log.error("收敛失败：\(error.localizedDescription)")
            }
        }
    }

    private func startWatchdog() {
        // 必须在主线程调度（runBusy 的后台闭包里调用时，Timer 会挂在永不运行的
        // GCD 线程 run loop 上，永不触发——实测 state.json 停更的根因）。
        DispatchQueue.main.async {
            self.startWatchdogOnMain()
        }
    }

    private func startWatchdogOnMain() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !self.busy else { return }
            // 逐槽存活 → 差异收敛只重建丢失槽；逐实例保活（停用屏不拉起）
            self.runBusy {
                do {
                    try self.reconcileNow()
                } catch {
                    Log.error("看门狗收敛失败：\(error.localizedDescription)")
                }
                for display in self.config.displays where display.enabled && display.sunshinePort != nil {
                    if let manager = self.registry?.managerIfExists(for: display.id),
                       manager.statusLine() == "未运行" {
                        Log.info("看门狗：实例 \(display.name) 未运行，重新拉起")
                        try? manager.start()
                    }
                }
                self.orchestrator?.streamMonitor.pollNow()   // 串流状态对账
            }
            // 屏幕捕获授权完成 → 重启全部运行中实例（启动期编码器探测需要权限）
            let granted = CapturePermission.granted
            if !self.restartedSunshineAfterGrant,
               self.lastCapturePermission == false, granted {
                self.restartedSunshineAfterGrant = true
                self.lastCapturePermission = granted
                Log.info("屏幕捕获权限已授予，重启全部实例重跑编码器探测")
                self.restartAllInstances()
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
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.runModal()
        }
    }
}

extension AppController.Phase {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
