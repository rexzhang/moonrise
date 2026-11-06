import XCTest
@testable import MoonriseCore

final class DisplaySpecTests: XCTestCase {
    func testDefaultSpecIsValid() throws {
        XCTAssertNoThrow(try DisplaySpec.default.validated())
    }

    func testValidationBounds() {
        XCTAssertThrowsError(try DisplaySpec(name: "x", width: 63, height: 1600, refreshRate: 60).validated())
        XCTAssertThrowsError(try DisplaySpec(name: "x", width: 16_385, height: 1600, refreshRate: 60).validated())
        XCTAssertThrowsError(try DisplaySpec(name: "x", width: 2560, height: 1600, refreshRate: 0).validated())
        XCTAssertThrowsError(try DisplaySpec(name: "x", width: 2560, height: 1600, refreshRate: 241).validated())
        XCTAssertThrowsError(try DisplaySpec(name: "", width: 2560, height: 1600, refreshRate: 60).validated())
    }

    func testModeSpecsContainLogicalMode() throws {
        let spec = DisplaySpec(name: "Sunshine Ext", width: 2560, height: 1600, refreshRate: 60)
        let modes = spec.modeSpecs
        XCTAssertEqual(modes.count, 2)
        XCTAssertEqual(modes[0][0].intValue, 2560)
        XCTAssertEqual(modes[0][1].intValue, 1600)
        XCTAssertEqual(modes[1][0].intValue, 1280)   // 逻辑模式 → 全倍 Retina 合成的关键
        XCTAssertEqual(modes[1][1].intValue, 800)
    }

    func testSmallSpecSkipsLogicalMode() {
        let spec = DisplaySpec(name: "x", width: 100, height: 80, refreshRate: 60)
        XCTAssertFalse(spec.supportsLogicalMode)
        XCTAssertEqual(spec.modeSpecs.count, 1)
    }

    func testBoundsAcceptance() {
        let spec = DisplaySpec(name: "s", width: 2560, height: 1600, refreshRate: 60)
        // 1:1 初始模式
        XCTAssertTrue(DisplayList.boundsAcceptable(CGRect(x: 0, y: 0, width: 2560, height: 1600), spec: spec))
        // 用户已选中 Retina 逻辑模式并按身份记忆
        XCTAssertTrue(DisplayList.boundsAcceptable(CGRect(x: 0, y: 0, width: 1280, height: 800), spec: spec))
        // 记忆了别的模式 → 需要带盐重建
        XCTAssertFalse(DisplayList.boundsAcceptable(CGRect(x: 0, y: 0, width: 1920, height: 1200), spec: spec))
    }
}
