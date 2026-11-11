import XCTest
@testable import MoonRiseCore

final class AppConfigTests: XCTestCase {
    func testLegacySingleDisplayMigratesToArray() throws {
        let json = """
        {
          "display": { "name": "Moon", "width": 2560, "height": 1600, "refreshRate": 60, "keepHostScaling": true }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.displays.count, 1)
        let display = try XCTUnwrap(config.displays.first)
        XCTAssertEqual(display.slotNumber, 1)
        XCTAssertEqual(display.name, "Moon 1")   // 统一编号语义（D8：该屏记忆一次性重置）
        XCTAssertEqual(display.width, 2560)
        XCTAssertEqual(display.height, 1600)
        XCTAssertEqual(display.refreshRate, 60)
        XCTAssertTrue(display.hiDPI)
        XCTAssertTrue(display.enabled)
        XCTAssertNil(display.sunshinePort)
    }

    func testKeepHostScalingMigratedFromLegacyDisplay() throws {
        let json = #"{"display": {"width": 1920, "height": 1200, "refreshRate": 60, "keepHostScaling": false}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.keepHostScaling)
        XCTAssertEqual(config.displays.first?.width, 1920)
    }

    func testTopLevelKeepHostScalingWinsOverLegacy() throws {
        let json = #"{"keepHostScaling": true, "display": {"width": 2560, "height": 1600, "refreshRate": 60, "keepHostScaling": false}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.keepHostScaling)
    }

    func testMissingEverythingFallsBackToDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.displays.count, 1)
        XCTAssertEqual(config.displays[0].name, "Moon 1")
        XCTAssertEqual(config.displays[0].width, 2560)
        XCTAssertEqual(config.displays[0].height, 1600)
        XCTAssertTrue(config.keepHostScaling)
    }

    func testNewShapeRoundTripPreservesSlots() throws {
        let first = DisplayConfig(slotNumber: 1, name: "Moon 1", width: 2560, height: 1600, refreshRate: 60)
        let second = DisplayConfig(
            slotNumber: 2, name: "Moon 2", width: 1920, height: 1080,
            refreshRate: 60, hiDPI: false, enabled: false, sunshinePort: 48089)
        let config = AppConfig(displays: [first, second])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.displays[1].id, second.id)
        XCTAssertEqual(decoded.displays[1].sunshinePort, 48089)
        XCTAssertFalse(decoded.displays[1].hiDPI)
        XCTAssertFalse(decoded.displays[1].enabled)
    }

    func testPrimaryDisplayPrefersEnabled() {
        var config = AppConfig()
        config.displays = [
            DisplayConfig(slotNumber: 1, name: "Moon 1", width: 2560, height: 1600, refreshRate: 60, enabled: false),
            DisplayConfig(slotNumber: 2, name: "Moon 2", width: 1920, height: 1080, refreshRate: 60),
        ]
        XCTAssertEqual(config.primaryDisplay?.name, "Moon 2")
    }
}
