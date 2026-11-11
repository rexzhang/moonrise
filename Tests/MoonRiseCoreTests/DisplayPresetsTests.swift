import XCTest
@testable import MoonRiseCore

final class DisplayPresetsTests: XCTestCase {
    func testAllPresetsPassValidation() {
        for preset in DisplayPresets.all {
            let spec = DisplaySpec(
                name: "Moon", width: preset.width, height: preset.height,
                refreshRate: preset.refreshRate, hiDPI: preset.hiDPI)
            XCTAssertNoThrow(try spec.validated(), "预设 \(preset.name) 未通过规格校验")
        }
    }

    func testGroupCounts() {
        XCTAssertEqual(DisplayPresets.macbook.count, 5)
        XCTAssertEqual(DisplayPresets.ipad.count, 6)
        XCTAssertEqual(DisplayPresets.appleDisplay.count, 3)
        XCTAssertEqual(DisplayPresets.general.count, 4)
        XCTAssertEqual(DisplayPresets.all.count, 18)
    }

    func testApplePresetsEnableHiDPI() {
        XCTAssertTrue((DisplayPresets.macbook + DisplayPresets.ipad + DisplayPresets.appleDisplay)
            .allSatisfy(\.hiDPI))
    }

    func testGeneralGroupHiDPIMarks() {
        let flags = DisplayPresets.general.map(\.hiDPI)
        XCTAssertEqual(flags, [false, false, false, true], "仅 4K 预设开 HiDPI")
    }

    func testNoDuplicateResolutionAndHiDPICombo() {
        let keys = DisplayPresets.all.map { "\($0.width)x\($0.height)|\($0.hiDPI)" }
        XCTAssertEqual(Set(keys).count, keys.count, "同一分辨率+HiDPI 组合不应重复")
    }
}
