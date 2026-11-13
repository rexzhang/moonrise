// AppController.swift — App 主体：生命周期壳 + 多屏编排接线 + 守护。
// 菜单栏由 SwiftUI MenuBarExtra 承载（MenuBarPanelView），本类只暴露可观察状态；
// 全部管理操作收敛于设置窗口（SettingsCoordinator）。

import AppKit
import Combine
import CoreGraphics
import ServiceManagement
import MoonRiseCore

final class AppController: NSObject, NSApplicationDelegate {
    // MARK: - 状态

    enum Phase: Equatable {
        case starting
        case locked          // Sunshine 未获取：不建屏/不启实例，引导设置窗口 Sunshine 页
        case running
        case degraded(message: String)
    }

    /// 每屏摘要（菜单面板 / 诊断 / 管理窗口共用）
    struct ScreenSummary: Identifiable {
        var id: UUID { slotID }
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

    private let store = ConfigStore()
    /// 设置读取快照（写侧一律经 store.mutate）
    private var config: AppConfig { store.config }
    private let sunshineStore = ManagedSunshineStore()
    private var virtualController: VirtualDisplayController?
    private var sunshineManager: SunshineManaging
    private var registry: SunshineInstanceRegistry?
    private var orchestrator: DisplayOrchestrator?

    // 真源状态（面板快照经 syncPanel 主线程推送到 PanelModel）
    private var phase: Phase = .starting
    private var busy = false
    private var watchdog: Timer?
    private var lastCapturePermission: Bool?
    private var restartedSunshineAfterGrant = false
    private var lastPanelError: String?

    // MARK: - 生命周期

    override init() {
        sunshineManager = ChildProcessSunshineManager(
            binPath: Paths.managedSunshineExecutableURL.path,
            confPath: Paths.expandTilde(store.config.sunshine.configPath),
            logURL: Paths.stateDirectory.appendingPathComponent("sunshine-child.log"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI 入口下的原 main.swift 职责：菜单栏 App 始终从附件形态启动
        NSApp.setActivationPolicy(.accessory)
        // SettingsLink 直接开窗不经过 showSettings：模型刷新挂窗口出现钩子
        SettingsCoordinator.shared.onSettingsShown = { [weak self] in
            self?.wireScreenCallbacks()
            self?.refreshScreenModel()
        }
        syncPanel()

        runBusy {
            // Sunshine 就绪判定唯一来源：受管副本（ManagedSunshineStore.isReady）。
            // 未获取 → 锁定态：不建屏/不启实例/不同步 conf，引导设置窗口 Sunshine 页。
            guard ManagedSunshineStore.isReady() else {
                self.phase = .locked
                Log.info("Sunshine 未获取：进入锁定态，打开设置窗口 Sunshine 页")
                DispatchQueue.main.async {
                    self.syncPanel()
                    self.showSettings(page: .sunshine)
                }
                return
            }
            self.startRunning()
        }
    }

    /// 就绪路径：建编排栈 → 权限引导 → 建屏起实例 → 看门狗。
    /// 启动与「获取/更新 Sunshine 完成」共用（后台队列调用）。
    private func startRunning() {
        do {
            let controller = try VirtualDisplayController()
            let registry = SunshineInstanceRegistry(
                sourceBinaryPath: Paths.managedSunshineExecutableURL.path)
            let orchestrator = DisplayOrchestrator(
                controller: controller,
                registry: registry,
                primaryManager: self.sunshineManager,
                configProvider: { [weak self] in self?.store.config ?? AppConfig() },
                liveDisplayIDs: { [weak self] in self?.liveIDs() ?? [] })
            orchestrator.streamMonitor.onStreamingChanged = { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.writeState()
                }
            }
            orchestrator.streamMonitor.start()
            self.virtualController = controller
            self.registry = registry
            self.orchestrator = orchestrator

            self.registerReconfigurationCallback()
            // 权限引导：屏幕捕获或输入控制缺失时自动打开设置窗口「权限」页
            self.lastCapturePermission = CapturePermission.granted
            if !CapturePermission.granted || !CapturePermission.inputControlGranted {
                DispatchQueue.main.async { self.showSettings(page: .permission) }
                Log.info("屏幕捕获/输入控制权限缺失：已打开设置窗口权限页")
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
            // refreshMenu 触碰 NSMenu/NSStatusItem（窗口布局），必须主线程：
            // realize 泵后台线程 run loop 时，排在其上的 AppKit 任务会被执行，
            // 非主线程窗口布局触发 CoreAutoLayout 断言直接 abort（14:12 崩溃实测）。
            DispatchQueue.main.async { self.syncPanel() }
        } catch {
            self.degrade(error: error)
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

    /// 菜单面板整行点击：反转该屏启用（失败置面板内联错误）。
    func toggleScreen(slotID: UUID) {
        guard let display = config.displays.first(where: { $0.id == slotID }) else { return }
        var updated = display
        updated.enabled.toggle()
        setEnabled(updated, fromMenu: true)
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
        syncPanel()
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

    /// 菜单面板快照刷新：真源状态主线程推送到 PanelModel（驱动 MenuBarExtra 重渲染）。
    private func syncPanel() {
        let currentPhase = phase
        let snapshots = screenSummaries()
        let currentBusy = busy
        DispatchQueue.main.async {
            let panel = PanelModel.shared
            panel.phase = currentPhase
            panel.summaries = snapshots
            panel.busy = currentBusy
        }
    }

    /// 面板内联错误（5s 自动清除）。
    private func setPanelError(_ message: String) {
        lastPanelError = message
        DispatchQueue.main.async {
            PanelModel.shared.panelError = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if PanelModel.shared.panelError == message {
                    PanelModel.shared.panelError = nil
                }
            }
        }
    }

    private func runBusy(_ work: @escaping () -> Void, completion: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        DispatchQueue.main.async { PanelModel.shared.busy = true }
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async {
                self.busy = false
                self.writeState()
                completion?()
            }
        }
    }

    /// 登录项注册状态（通用页开关初值）。
    private var loginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func resyncAll() {
        runBusy {
            do {
                try self.reconcileNow()
            } catch {
                Log.error("重新同步失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sunshine 受管获取

    /// 获取/更新受管 Sunshine：下载 → 验签 → 停运行栈 → 原子换装 → 重建就绪栈。
    /// tag = nil 跟随最新；force=true（重新获取）语义相同（同 tag 重下）。
    private func acquireSunshine(force: Bool) {
        let model = SettingsCoordinator.shared.model
        guard model.acquirePhase == nil else { return }
        model.sunshineMessage = nil
        let tag = config.sunshine.selectedVersion == "latest" ? nil : config.sunshine.selectedVersion
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let staged = try await self.sunshineStore.acquire(tag: tag) { phase, done, total in
                    DispatchQueue.main.async {
                        model.acquirePhase = phase
                        model.acquireDone = done
                        model.acquireTotal = total
                    }
                }
                self.stopRunningStack()
                DispatchQueue.main.async { model.acquirePhase = .swapping }
                try self.sunshineStore.swapIn(stagedBundle: staged)
                UserDefaults.standard.set(true, forKey: "sunshine.migrationDone")
                self.startRunning()
                DispatchQueue.main.async {
                    model.acquirePhase = nil
                    model.sunshineMessage = "已就绪" + (ManagedSunshineStore.installedVersion().map { " v\($0)" } ?? "")
                    self.refreshScreenModel()
                }
            } catch {
                DispatchQueue.main.async {
                    model.acquirePhase = nil
                    model.sunshineMessage = "获取失败：\(error.localizedDescription)"
                    self.refreshScreenModel()
                }
            }
        }
    }

    /// 换装前停机：销屏 + 串行停全部实例 + 清编排栈（回锁定态直至新副本就绪）。
    private func stopRunningStack() {
        guard phase == .running else { return }
        orchestrator?.shutdown()
        for display in config.displays where display.sunshinePort != nil {
            if let manager = registry?.managerIfExists(for: display.id) {
                try? manager.stop()
            }
        }
        try? sunshineManager.stop()
        DispatchQueue.main.async {
            self.watchdog?.invalidate()
            self.watchdog = nil
            self.syncPanel()
        }
        virtualController = nil
        registry = nil
        orchestrator = nil
        phase = .locked
    }

    /// 检查更新（手动）：releases/latest 与已装版本比较。
    private func checkSunshineUpdates() {
        let model = SettingsCoordinator.shared.model
        model.sunshineMessage = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let latest = try await self.sunshineStore.fetchLatest()
                DispatchQueue.main.async {
                    model.latestKnown = latest
                    let installedTag = ManagedSunshineStore.installedVersion().map { "v" + $0 }
                    switch (ManagedSunshineStore.isReady(), installedTag) {
                    case (true, .some(let installed)) where latest.tag == installed:
                        model.sunshineMessage = "已是最新版本"
                    case (true, .some(let installed)) where ManagedSunshineStore.isVersion(latest.tag, atLeast: installed):
                        model.sunshineMessage = "有新版本 \(latest.tag)，点「更新」安装"
                    case (true, .some(let installed)):
                        model.sunshineMessage = "已装版本 \(installed) 晚于最新发布"
                    default:
                        model.sunshineMessage = "最新版本 \(latest.tag)，点「获取」安装"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    model.sunshineMessage = "检查更新失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 版本列表加载（版本选择展开时；近 20 条）。
    private func loadSunshineReleases() {
        let model = SettingsCoordinator.shared.model
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let releases = try await self.sunshineStore.fetchReleases(limit: 20)
                DispatchQueue.main.async { model.releases = releases }
            } catch {
                DispatchQueue.main.async {
                    model.sunshineMessage = "版本列表加载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func restartAllInstances() {
        runBusy {
            try? self.sunshineManager.restart()
            for display in self.config.displays where display.enabled && display.sunshinePort != nil {
                if let manager = try? self.registry?.manager(for: display) {
                    try? manager.restart()
                }
            }
        }
    }

    /// 禁用音频串流（设置通用页）：值变才重启受影响实例（精确到实例）。
    private func toggleAudioStreaming(disabled: Bool) {
        guard config.sunshine.disableAudioStreaming != disabled else { return }
        store.mutate { $0.sunshine.disableAudioStreaming = disabled }
        resyncAll()
    }

    /// 诊断页数据源：主线程快照 → 后台跑检查 → 主线程回调（设置窗口「切入即检查」）。
    private func runDiagnostics(completion: @escaping ([DiagnosticsModel.CheckRow]) -> Void) {
        let context = DiagnosticsModel.Context(
            screens: screenSummaries().map { summary in
                DiagnosticsModel.ScreenDiagnostics(
                    name: summary.name,
                    slotID: summary.slotID,
                    displayID: summary.displayID,
                    isLive: summary.displayID.map { liveIDs().contains($0) } ?? false,
                    spec: summary.spec,
                    port: summary.port,
                    enabled: summary.enabled,
                    syncStatus: summary.syncStatus)
            })
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = DiagnosticsModel.runChecks(context: context)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// 开机自启（设置通用页唯一入口；失败弹框提示安装场景限制）。
    private func setLoginItem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            DispatchQueue.main.async {
                SettingsCoordinator.shared.model.loginItemAlert = "\(error.localizedDescription)\n\n从 swift run 直接启动无法注册登录项；请先用 scripts/install-app.sh 安装为 App。"
            }
        }
        refreshScreenModel()
    }

    // MARK: - 扩展屏幕管理（SwiftUI 三窗：列表 / 修改 / 配对）

    private func showSettings(page: SettingsPage? = nil) {
        wireScreenCallbacks()
        refreshScreenModel()
        SettingsCoordinator.shared.showSettings(page: page)
    }

    private func refreshScreenModel() {
        let displays = config.displays
        let summaries = screenSummaries()
        let keep = config.keepHostScaling
        let audio = config.sunshine.disableAudioStreaming
        let login = loginItemEnabled
        let lan = Self.lanAddresses()
        let primaryCredentialsURL = InstanceWebAPI.primaryWebUICredentialsURL(configPath: config.sunshine.configPath)
        DispatchQueue.main.async {
            let model = SettingsCoordinator.shared.model
            model.refresh(
                displays: displays,
                summaries: summaries,
                keepHostScaling: keep,
                disableAudioStreaming: audio,
                loginItemEnabled: login,
                lanAddresses: lan)
            model.primaryCredentialsURL = primaryCredentialsURL
            model.sunshineReady = ManagedSunshineStore.isReady()
            model.sunshineInstalledVersion = ManagedSunshineStore.installedVersion()
            model.selectedVersion = self.config.sunshine.selectedVersion
            model.sunshineConfigPath = Paths.expandTilde(self.config.sunshine.configPath)
            model.legacySignal = self.hasLegacySunshineSignal()
                && !UserDefaults.standard.bool(forKey: "sunshine.migrationDone")
        }
    }

    /// 存量 Sunshine 形态检测：旧 config(.imported) 含 binaryPath，或主 conf/凭据目录存在。
    private func hasLegacySunshineSignal() -> Bool {
        let fm = FileManager.default
        for name in ["config.json", "config.json.imported"] {
            let url = Paths.configURL.deletingLastPathComponent().appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sunshine = object["sunshine"] as? [String: Any],
               sunshine["binaryPath"] != nil {
                return true
            }
        }
        return fm.fileExists(atPath: Paths.expandTilde(AppConfig().sunshine.configPath))
    }

    private func wireScreenCallbacks() {
        let model = SettingsCoordinator.shared.model
        model.callbacks = ScreenCallbacks(
            toggleEnabled: { [weak self] display, fromMenu in self?.setEnabled(display, fromMenu: fromMenu) },
            restartSlot: { [weak self] slotID in self?.restartSlot(slotID: slotID) },
            openWebUI: { port in
                if let url = URL(string: "https://localhost:\(port)") {
                    NSWorkspace.shared.open(url)
                }
            },
            deleteSlot: { [weak self] display in self?.deleteSlot(display) },
            resetPrimary: { [weak self] display in self?.resetPrimaryScreen(display) },
            applyEdit: { [weak self] candidate, reportError in
                self?.applySlotEdit(candidate, reportError: reportError)
            },
            applyAdd: { [weak self] candidate, reportError in
                self?.addScreen(candidate, reportError: reportError)
            },
            setKeepHostScaling: { [weak self] enabled in
                self?.store.mutate { $0.keepHostScaling = enabled }
            },
            setDisableAudioStreaming: { [weak self] disabled in self?.toggleAudioStreaming(disabled: disabled) },
            setLoginItem: { [weak self] enabled in self?.setLoginItem(enabled) },
            restartAllInstances: { [weak self] in self?.restartAllInstances() },
            resyncAll: { [weak self] in self?.resyncAll() },
            requestCapturePermission: { CapturePermission.request() },
            requestInputControlPermission: { CapturePermission.requestInputControl() },
            openCaptureSystemSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.privacy?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            },
            restartPrimarySunshine: { [weak self] in
                DispatchQueue.global(qos: .userInitiated).async {
                    try? self?.sunshineManager.restart()
                }
            })
        model.sunshineCallbacks = SunshineCallbacks(
            acquire: { [weak self] in self?.acquireSunshine(force: false) },
            refetch: { [weak self] in self?.acquireSunshine(force: true) },
            checkUpdates: { [weak self] in self?.checkSunshineUpdates() },
            loadReleases: { [weak self] in self?.loadSunshineReleases() },
            setSelectedVersion: { [weak self] version in
                self?.store.mutate { $0.sunshine.selectedVersion = version }
                DispatchQueue.main.async {
                    SettingsCoordinator.shared.model.selectedVersion = version
                }
            },
            restartPrimary: { [weak self] in
                DispatchQueue.global(qos: .userInitiated).async {
                    try? self?.sunshineManager.restart()
                }
            })
        model.diagnosticsProvider = { [weak self] completion in
            self?.runDiagnostics(completion: completion)
        }
        model.sunshineProcessProvider = { [weak self] in
            self?.sunshineManager.statusLine() ?? "未运行"
        }
        model.sunshineHealthProvider = { [weak self] in
            guard let self else { return [] }
            let screens = self.screenSummaries().map { summary in
                DiagnosticsModel.ScreenDiagnostics(
                    name: summary.name,
                    slotID: summary.slotID,
                    displayID: summary.displayID,
                    isLive: summary.displayID.map { self.liveIDs().contains($0) } ?? false,
                    spec: summary.spec,
                    port: summary.port,
                    enabled: summary.enabled,
                    syncStatus: summary.syncStatus)
            }
            return DiagnosticsModel.sunshineChecks(screens: screens)
        }
        model.permissionProvider = { [weak self] in
            guard let self else { return nil }
            return PermissionStatusSnapshot(
                captureGranted: CapturePermission.granted,
                inputGranted: CapturePermission.inputControlGranted)
        }
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

    private func setEnabled(_ display: DisplayConfig, fromMenu: Bool = false) {
        runBusy {
            do {
                try ScreenChangeValidator.validate(display, others: self.config.displays)
                guard self.config.displays.contains(where: { $0.id == display.id }) else { return }
                self.store.mutate { config in
                    guard let idx = config.displays.firstIndex(where: { $0.id == display.id }) else { return }
                    config.displays[idx] = display
                }
                try self.orchestrator?.setEnabled(display)
            } catch {
                Log.error("启用/停用失败：\(error.localizedDescription)")
                if fromMenu {
                    self.setPanelError("切换「\(display.name)」失败：\(error.localizedDescription)")
                } else {
                    SettingsCoordinator.shared.model.reportError(display.id, error.localizedDescription)
                }
            }
        }
    }

    private func deleteSlot(_ display: DisplayConfig) {
        runBusy {
            do {
                try self.orchestrator?.remove(slotID: display.id)
                self.store.mutate { config in
                    config.displays.removeAll { $0.id == display.id }
                }
                try? FileManager.default.removeItem(at: InstanceConf.directory(for: display.id))
                // 编辑窗口监听 displays 变化自动关闭（原 closeEdit 语义）
            } catch {
                Log.error("删除失败：\(error.localizedDescription)")
                SettingsCoordinator.shared.model.reportError(display.id, error.localizedDescription)
            }
        }
    }

    /// 首屏重置（卡片动作）：恢复默认名与规格 + 清主实例账号与配对（回全新安装状态）。
    /// 停用屏只写配置与清凭据，启用后生效；启用屏经 rebuild 联动主实例按值变重启。
    private func resetPrimaryScreen(_ display: DisplayConfig) {
        runBusy {
            do {
                let defaults = DisplayConfig(
                    id: display.id,
                    slotNumber: display.slotNumber,
                    name: "Moon \(display.slotNumber)",
                    width: 2560,
                    height: 1600,
                    refreshRate: 60,
                    hiDPI: true,
                    enabled: display.enabled,
                    sunshinePort: display.sunshinePort)
                try ScreenChangeValidator.validate(
                    defaults, others: self.config.displays.filter { $0.id != display.id })
                var wasEnabled = false
                self.store.mutate { config in
                    guard let idx = config.displays.firstIndex(where: { $0.id == display.id }) else { return }
                    wasEnabled = config.displays[idx].enabled
                    config.displays[idx] = defaults
                }
                Self.removePrimaryCredentials(configPath: self.config.sunshine.configPath)
                if wasEnabled {
                    // conf 值变（sunshine_name / output_name）→ 重启主实例，读已清空凭据 = 新装状态
                    try self.orchestrator?.rebuild(defaults)
                } else {
                    try? self.sunshineManager.stop()
                }
            } catch {
                Log.error("重置失败：\(error.localizedDescription)")
                SettingsCoordinator.shared.model.reportError(display.id, error.localizedDescription)
            }
        }
    }

    /// 清主实例账号与配对：sunshine_state.json（Web 凭据 + 配对设备）与 credentials/（证书对）。
    /// 主 Sunshine 重启时自动重建——Moonlight 端已配对设备全部失效，需重新配对。
    private static func removePrimaryCredentials(configPath: String) {
        let dir = URL(fileURLWithPath: Paths.expandTilde(configPath)).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("sunshine_state.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("credentials"))
    }

    private func applySlotEdit(_ newDisplay: DisplayConfig, reportError: @escaping (String?) -> Void) {
        runBusy {
            do {
                try ScreenChangeValidator.validate(newDisplay, others: self.config.displays)
                var before: DisplayConfig?
                self.store.mutate { config in
                    guard let idx = config.displays.firstIndex(where: { $0.id == newDisplay.id }) else { return }
                    before = config.displays[idx]
                    config.displays[idx] = newDisplay
                }
                guard let before else {
                    reportError("屏幕不存在")
                    return
                }
                if before.enabled != newDisplay.enabled {
                    try self.orchestrator?.setEnabled(newDisplay)
                } else if newDisplay.enabled {
                    try self.orchestrator?.rebuild(newDisplay)
                }
                // 停用屏：只写配置，启用时按新规格生效
                reportError(nil)   // 成功：关窗（与添加模式一致）
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
                Log.info("添加屏幕：开始应用（\(candidate.width)×\(candidate.height)）")
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
                self.store.mutate { config in
                    config.displays.append(display)
                }
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

    /// 全部有效 IPv4 地址（回环除外；物理网卡 en* 优先排序，去重保序）。
    static func lanAddresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var physical: [String] = []
        var others: [String] = []
        var seen = Set<String>()
        var ptr = ifaddr
        while let current = ptr {
            let ifa = current.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1", !seen.contains(ip) {
                        seen.insert(ip)
                        if String(cString: ifa.ifa_name).hasPrefix("en") {
                            physical.append(ip)
                        } else {
                            others.append(ip)
                        }
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return physical + others
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

}
