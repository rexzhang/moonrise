import XCTest
import CoreGraphics
@testable import MoonRiseCore

final class DisplayReconcilePlanTests: XCTestCase {
    /// 槽位 UUID 由编号确定性构造，便于断言
    private func display(
        _ slot: Int,
        name: String = "Moon",
        width: Int = 2560,
        height: Int = 1600,
        hiDPI: Bool = true,
        enabled: Bool = true,
        port: Int? = nil
    ) -> DisplayConfig {
        DisplayConfig(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", slot))!,
            slotNumber: slot,
            name: name,
            width: width,
            height: height,
            refreshRate: 60,
            hiDPI: hiDPI,
            enabled: enabled,
            sunshinePort: port)
    }

    private func realized(_ config: DisplayConfig) -> (id: UUID, display: RealizedDisplay) {
        (config.id, RealizedDisplay(
            displayID: CGDirectDisplayID(100 + config.slotNumber),
            spec: config.spec,
            identity: config.spec.identity))
    }

    func testCreateWhenConfiguredWithoutRuntime() {
        let d1 = display(1)
        let plan = DisplayReconcilePlan.plan(configured: [d1], realized: [:])
        XCTAssertEqual(plan.toCreate, [d1])
        XCTAssertTrue(plan.toRemove.isEmpty)
        XCTAssertTrue(plan.toRebuild.isEmpty)
        XCTAssertTrue(plan.toKeep.isEmpty)
    }

    func testKeepWhenSpecMatches() {
        let d1 = display(1)
        let (id, current) = realized(d1)
        let plan = DisplayReconcilePlan.plan(configured: [d1], realized: [id: current])
        XCTAssertEqual(plan.toKeep, [d1])
        XCTAssertTrue(plan.toCreate.isEmpty)
    }

    func testRebuildOnWidthChange() {
        let d1 = display(1)
        let modified = display(1, width: 1920)
        let (id, current) = realized(d1)
        let plan = DisplayReconcilePlan.plan(configured: [modified], realized: [id: current])
        XCTAssertEqual(plan.toRebuild, [modified])
    }

    func testRebuildOnRename() {
        let d1 = display(1, name: "Moon 1")
        let renamed = display(1, name: "工作屏")
        let (id, current) = realized(d1)
        let plan = DisplayReconcilePlan.plan(configured: [renamed], realized: [id: current])
        XCTAssertEqual(plan.toRebuild, [renamed])
    }

    func testRebuildOnHiDPIToggle() {
        let d1 = display(1)
        let toggled = display(1, hiDPI: false)
        let (id, current) = realized(d1)
        let plan = DisplayReconcilePlan.plan(configured: [toggled], realized: [id: current])
        XCTAssertEqual(plan.toRebuild, [toggled])
    }

    func testPortChangeDoesNotRebuild() {
        let d1 = display(1, port: nil)
        let reflowed = display(1, port: 48089)
        let (id, current) = realized(d1)
        let plan = DisplayReconcilePlan.plan(configured: [reflowed], realized: [id: current])
        XCTAssertEqual(plan.toKeep, [reflowed], "端口变化只重写实例 conf，不触发重建（D3 冻结语义）")
    }

    func testDisabledScreenTriggersRemove() {
        let d1 = display(1)
        let disabled = display(1, enabled: false)
        let (id, current) = realized(d1)
        let plan = DisplayReconcilePlan.plan(configured: [disabled], realized: [id: current])
        XCTAssertEqual(plan.toRemove, [d1.id], "停用屏视为未配置（D10），运行态应收敛移除")
        XCTAssertTrue(plan.toKeep.isEmpty)
    }

    func testRemoveWhenRuntimeWithoutConfig() {
        let d1 = display(1)
        let (id, current) = realized(d1)
        let plan = DisplayReconcilePlan.plan(configured: [], realized: [id: current])
        XCTAssertEqual(plan.toRemove, [d1.id])
    }

    func testMixedPlanOrderedBySlotNumber() {
        let d1 = display(1)                        // keep
        let d2 = display(2)                        // rebuild（改宽）
        let d3 = display(3, name: "Moon 3")        // create
        let modifiedD2 = display(2, width: 1920)
        let (r1Id, r1) = realized(d1)
        let (r2Id, r2) = realized(d2)
        let plan = DisplayReconcilePlan.plan(configured: [d1, modifiedD2, d3], realized: [r1Id: r1, r2Id: r2])
        XCTAssertEqual(plan.toKeep, [d1])
        XCTAssertEqual(plan.toRebuild, [modifiedD2])
        XCTAssertEqual(plan.toCreate, [d3])
    }
}
