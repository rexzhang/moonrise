import XCTest
@testable import MoonRiseCore

final class SunshineProcessDiscoveryTests: XCTestCase {
    private let selfPID = pid_t(1000)

    func testForeignExcludesSelfAndManagedChildren() {
        let candidates: [pid_t] = [1000, 2000, 2001, 3000]
        let foreign = SunshineProcessDiscovery.foreignPIDs(
            candidates: candidates,
            managedChildren: [2000, 2001],
            selfPID: selfPID,
            parentOf: { _ in nil })
        XCTAssertEqual(foreign, [3000])
    }

    func testForeignExcludesDirectChildrenEvenIfNotTracked() {
        // 双保险：ppid == 自身的进程一律不算外部（家族集合遗漏时兜底）
        let candidates: [pid_t] = [2000, 4000]
        let foreign = SunshineProcessDiscovery.foreignPIDs(
            candidates: candidates,
            managedChildren: [],
            selfPID: selfPID,
            parentOf: { pid in pid == 2000 ? selfPID : pid_t(99) })
        XCTAssertEqual(foreign, [4000])
    }

    func testAllManagedMeansNoForeign() {
        let candidates: [pid_t] = [2000, 2001]
        let foreign = SunshineProcessDiscovery.foreignPIDs(
            candidates: candidates,
            managedChildren: [2000, 2001],
            selfPID: selfPID,
            parentOf: { _ in selfPID })
        XCTAssertTrue(foreign.isEmpty)
    }

    func testManagedProcessFamilyAddRemove() {
        let family = ManagedProcessFamily()
        family.add(2000)
        family.add(2001)
        XCTAssertEqual(foreign(family, candidates: [2000, 3000]), [3000])
        family.remove(2000)
        XCTAssertEqual(foreign(family, candidates: [2000, 3000]), [2000, 3000])
    }

    private func foreign(_ family: ManagedProcessFamily, candidates: [pid_t]) -> [pid_t] {
        family.foreign(from: candidates, parentOf: { _ in pid_t(99) })
    }
}
