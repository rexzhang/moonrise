import Foundation
import CoreGraphics

/// 单屏改动校验（W2 应用）：规格合法性 + 名称唯一 + 身份向量不撞（对其它屏）。
public enum ScreenChangeValidator {
    public enum ChangeError: LocalizedError {
        case duplicateName(String)
        case duplicateIdentity(String)

        public var errorDescription: String? {
            switch self {
            case .duplicateName(let name):
                return "「\(name)」已存在，请换一个名称"
            case .duplicateIdentity(let name):
                return "「\(name)」与其它屏的显示身份相同（同名同尺寸），请改名称或尺寸"
            }
        }
    }

    /// others：除目标屏外的全部配置槽位。
    public static func validate(_ display: DisplayConfig, others: [DisplayConfig]) throws {
        _ = try display.spec.validated()
        if others.contains(where: { $0.id != display.id && $0.name == display.name }) {
            throw ChangeError.duplicateName(display.name)
        }
        let serial = display.spec.identity.serialNumber
        if others.contains(where: { $0.id != display.id && $0.spec.identity.serialNumber == serial }) {
            throw ChangeError.duplicateIdentity(display.name)
        }
    }
}

/// 收敛动作。
public enum ReconcileAction: Equatable, Sendable {
    case create     // 配置有且已启用、运行无 → 建屏并建实例
    case remove     // 运行有、配置无或已停用 → 停实例并销屏
    case rebuild    // 同槽规格或名称变化 → 销毁重建该槽
    case keep       // 一致 → 不动（串流不中断）
}

/// 逐槽收敛计划（纯函数产出，不落盘不建屏）。
/// 端口变化不触发 rebuild（端口冻结于配置，只重写实例 conf）。
public struct DisplayReconcilePlan: Equatable, Sendable {
    public private(set) var toCreate: [DisplayConfig] = []
    public private(set) var toRemove: [UUID] = []
    public private(set) var toRebuild: [DisplayConfig] = []
    public private(set) var toKeep: [DisplayConfig] = []

    /// configured：完整配置数组（内部按 enabled 过滤，停用屏视为未配置——D10）；
    /// realized：运行态槽位表。结果按槽位编号排序，保持稳定的执行顺序。
    public static func plan(configured: [DisplayConfig], realized: [UUID: RealizedDisplay]) -> DisplayReconcilePlan {
        var plan = DisplayReconcilePlan()
        let enabled = configured
            .filter(\.enabled)
            .sorted { $0.slotNumber < $1.slotNumber }

        for display in enabled {
            if let current = realized[display.id] {
                if specMatches(current.spec, display) {
                    plan.toKeep.append(display)
                } else {
                    plan.toRebuild.append(display)
                }
            } else {
                plan.toCreate.append(display)
            }
        }

        let enabledIDs = Set(enabled.map(\.id))
        plan.toRemove = realized
            .keys
            .filter { !enabledIDs.contains($0) }
            .sorted { (realized[$0]?.displayID ?? 0) < (realized[$1]?.displayID ?? 0) }
        return plan
    }

    /// 规格一致性：名称/宽高/刷新率/HiDPI 任一变化即 rebuild；端口变化不参与（D3 冻结语义）。
    private static func specMatches(_ spec: DisplaySpec, _ display: DisplayConfig) -> Bool {
        spec.name == display.name
            && spec.width == display.width
            && spec.height == display.height
            && spec.refreshRate == display.refreshRate
            && spec.hiDPI == display.hiDPI
    }
}
