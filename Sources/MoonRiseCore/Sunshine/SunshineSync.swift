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

    /// 目标键值：output_name（虚拟屏）+ stream_audio（音频串流开关）
    static func targetValues(outputName: UInt32, config: AppConfig) -> [String: String] {
        var values = ["output_name": String(outputName)]
        values["stream_audio"] = config.sunshine.disableAudioStreaming ? "disabled" : "enabled"
        return values
    }

    /// 幂等联动入口。阻塞（可能重启服务 ~2s）：在后台队列调用。
    @discardableResult
    public static func sync(outputName: UInt32, config: AppConfig, manager: SunshineManaging) -> Outcome {
        guard config.sunshine.autoConfigure else { return .unchanged }
        guard manager.detect() != nil else { return .notInstalled }

        do {
            switch try ConfFile.syncValues(
                configPath: config.sunshine.configPath,
                values: targetValues(outputName: outputName, config: config)) {
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
