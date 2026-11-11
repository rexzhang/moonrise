import Foundation

/// Sunshine 联动：把虚拟屏 displayID 写进 output_name，变了才重启。
public enum SunshineSync {
    public enum Outcome: Equatable {
        case synced          // 已同步（含本次写盘并重启成功）
        case started         // managed：配置未变，确保了 Sunshine 在跑
        case unchanged       // 值本来就对，未动
        case notInstalled    // 未安装（提示安装指引）
        case missingConfig   // conf 不存在（提示先跑一次 Sunshine）
        case failed(String)  // 其它失败（原因）
    }

    /// 目标键值：output_name（虚拟屏）+ sunshine_name（对外屏名，与显示名一一对应）+ stream_audio（音频串流开关）
    static func targetValues(outputName: UInt32, displayName: String, config: AppConfig) -> [String: String] {
        var values = ["output_name": String(outputName)]
        values["sunshine_name"] = displayName
        values["stream_audio"] = config.sunshine.disableAudioStreaming ? "disabled" : "enabled"
        return values
    }

    /// 幂等联动入口。阻塞（可能重启服务 ~2s）：在后台队列调用。
    @discardableResult
    public static func sync(outputName: UInt32, displayName: String, config: AppConfig, manager: SunshineManaging) -> Outcome {
        guard config.sunshine.autoConfigure else { return .unchanged }
        guard manager.detect() != nil else { return .notInstalled }

        do {
            switch try ConfFile.syncValues(
                configPath: config.sunshine.configPath,
                values: targetValues(outputName: outputName, displayName: displayName, config: config)) {
            case .unchanged:
                // managed 语义下"配置正确"也要确保 Sunshine 在跑（start 幂等）
                if case .managed = config.sunshine.restartPolicy {
                    try manager.start()
                    return .started
                }
                return .unchanged
            case .changed:
                try applyRestart(config: config, manager: manager)
                return .synced
            }
        } catch let error as ConfFileError where error.isConfigMissing {
            return .missingConfig
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 扩展屏实例 conf 同步（幂等；缺失代建——实例 conf 为 MoonRise 自有文件）。
    /// 首屏（sunshinePort == nil）走主 conf 同步，此处直接 .unchanged。
    /// 返回 .synced 表示 conf 有变化（调用方重启该实例）；.unchanged 表示一致（调用方 start 保活）。
    public static func syncInstance(display: DisplayConfig, outputName: UInt32, audioDisabled: Bool) throws -> Outcome {
        guard display.sunshinePort != nil else { return .unchanged }
        let values = InstanceConf.targetValues(for: display, outputName: outputName, audioDisabled: audioDisabled)
        let result = try ConfFile.syncValues(
            configPath: InstanceConf.confURL(for: display.id).path,
            values: values,
            createsIfMissing: true)
        return result == .changed ? .synced : .unchanged
    }

    private static func applyRestart(config: AppConfig, manager: SunshineManaging) throws {
        switch config.sunshine.restartPolicy {
        case .brewServices:
            try manager.restart()
        case .managed:
            try manager.restart()
        case .manual:
            Log.info("restartPolicy=manual：请手动重启 Sunshine 使 output_name 生效")
        }
    }
}

extension ConfFileError {
    var isConfigMissing: Bool {
        if case .configMissing = self { return true }
        return false
    }
}
