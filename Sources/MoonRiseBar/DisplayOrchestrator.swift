// DisplayOrchestrator.swift — 多屏编排：配置 diff → 逐屏 realize/teardown → 逐实例 conf 同步与启动。
// 屏与实例的启动/重启一律串行执行（spike S7：并发探测互卡）。

import Foundation
import CoreGraphics
import MoonRiseCore

final class DisplayOrchestrator {
    private let controller: VirtualDisplayController
    private let registry: SunshineInstanceRegistry
    private let primaryManager: SunshineManaging            // 首屏（主 conf）
    private let configProvider: () -> AppConfig             // 读当前配置（AppController 持有）
    private let liveDisplayIDs: () -> [CGDirectDisplayID]   // 活动显示器快照

    /// 运行态：槽位 UUID → RealizedDisplay
    private(set) var realized: [UUID: RealizedDisplay] = [:]
    /// 每屏实例同步结果（诊断/卡片展示）
    private(set) var syncStatus: [UUID: String] = [:]
    /// 串流状态监控（日志尾随；回调由 AppController 接主线程刷新）
    let streamMonitor = StreamStateMonitor()

    init(
        controller: VirtualDisplayController,
        registry: SunshineInstanceRegistry,
        primaryManager: SunshineManaging,
        configProvider: @escaping () -> AppConfig,
        liveDisplayIDs: @escaping () -> [CGDirectDisplayID]
    ) {
        self.controller = controller
        self.registry = registry
        self.primaryManager = primaryManager
        self.configProvider = configProvider
        self.liveDisplayIDs = liveDisplayIDs
    }

    // MARK: - 全量收敛（启动 / 应用 / 看门狗共用）

    /// diff 收敛：只动差异槽，保留屏的串流不中断。
    /// 丢失槽（displayID 不在活动列表）按 create 处理 → realize 先销毁旧槽再建，等价单槽重建。
    func reconcile() throws {
        let config = configProvider()
        let live = Set(liveDisplayIDs())
        // 丢失槽视为未运行：从 realized 视图剔除，diff 自然给出重建
        let effective = realized.filter { live.contains($0.value.displayID) }
        let plan = DisplayReconcilePlan.plan(configured: config.displays, realized: effective)

        for slotID in plan.toRemove {
            try remove(slotID: slotID)
        }
        for display in plan.toCreate {
            try create(display)
        }
        for display in plan.toRebuild {
            try rebuild(display)
        }
        for display in plan.toKeep {
            try syncRuntime(display)
        }
    }

    // MARK: - 单槽动作

    /// 新增屏（配置已含该槽，预设即建）。阻塞：后台队列调用。
    func create(_ display: DisplayConfig) throws {
        let realizedDisplay = try controller.realize(slotID: display.id, spec: display.spec)
        realized[display.id] = realizedDisplay
        trackStreaming(display)
        try syncRuntime(display)
    }

    /// 单屏应用改动（改分辨率/刷新率/HiDPI/改名后调用；display 为已写入配置的新值）。
    func rebuild(_ display: DisplayConfig) throws {
        let realizedDisplay = try controller.realize(slotID: display.id, spec: display.spec)
        realized[display.id] = realizedDisplay
        trackStreaming(display)
        try syncRuntime(display)
    }

    /// 启用/停用切换（display 为已写入配置的新值）。
    func setEnabled(_ display: DisplayConfig) throws {
        if display.enabled {
            try create(display)
        } else {
            try suspend(slotID: display.id)
        }
    }

    /// 停实例 + 销屏 + 遗忘（删除屏/停用屏共用；配置的增删由调用方负责）。
    /// 首屏删除被 UI 禁止；首屏停用走 suspend 并由本方法停主实例。
    func remove(slotID: UUID) throws {
        streamMonitor.untrack(slotID: slotID)
        if isPrimarySlot(slotID) {
            try? primaryManager.stop()
        } else if let manager = registry.managerIfExists(for: slotID) {
            try? manager.stop()
            registry.forget(slotID: slotID)
        }
        realized[slotID] = nil
        syncStatus[slotID] = nil
        try controller.teardown(slotID: slotID)
    }

    /// 停用：停实例 + 销屏，配置槽位保留（看门狗/回调不复活停用屏）。
    /// 首屏停用时主实例一并停止（D10：防 output_name 悬空回退捕获 host 屏）。
    func suspend(slotID: UUID) throws {
        streamMonitor.untrack(slotID: slotID)
        if isPrimarySlot(slotID) {
            try? primaryManager.stop()
        } else if let manager = registry.managerIfExists(for: slotID) {
            try? manager.stop()
        }
        realized[slotID] = nil
        syncStatus[slotID] = nil
        try controller.teardown(slotID: slotID)
    }

    private func isPrimarySlot(_ slotID: UUID) -> Bool {
        configProvider().displays.first(where: { $0.id == slotID })?.sunshinePort == nil
    }

    /// 退出：全部销屏 + 停监控（实例停止由 AppController 编排：primary + registry 逐个 stop）。
    func shutdown() {
        streamMonitor.stop()
        for slotID in realized.keys {
            streamMonitor.untrack(slotID: slotID)
        }
        try? controller.teardownAll()
        realized.removeAll()
    }

    // MARK: - 实例联动

    /// 逐屏 Sunshine 联动：首屏走主 conf（现状语义），扩展屏走实例 conf（值变才重启该实例）。
    private func syncRuntime(_ display: DisplayConfig) throws {
        let config = configProvider()
        guard let displayID = realized[display.id]?.displayID else { return }
        if display.sunshinePort == nil {
            let outcome = SunshineSync.sync(
                outputName: displayID,
                config: config,
                manager: primaryManager)
            syncStatus[display.id] = Self.syncText(outcome)
            trackStreaming(display)
            return
        }

        let manager = try registry.manager(for: display)
        let outcome = try SunshineSync.syncInstance(
            display: display,
            outputName: displayID,
            audioDisabled: config.sunshine.disableAudioStreaming)
        switch outcome {
        case .synced:
            try manager.restart()   // 值变才重启该实例（串行：调用方保证不并发进入）
            syncStatus[display.id] = "已同步"
        case .unchanged:
            try manager.start()     // 幂等保活
            syncStatus[display.id] = "已同步"
        default:
            syncStatus[display.id] = "待处理"
        }
        trackStreaming(display)
    }

    /// 首屏日志走 sunshine-child.log（主 conf 无 log_path 分流），扩展屏走实例日志。
    private func trackStreaming(_ display: DisplayConfig) {
        let url = display.sunshinePort == nil
            ? Paths.stateDirectory.appendingPathComponent("sunshine-child.log")
            : InstanceConf.logURL(for: display.id)
        streamMonitor.track(slotID: display.id, logURL: url)
    }

    private static func syncText(_ outcome: SunshineSync.Outcome) -> String {
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
}
