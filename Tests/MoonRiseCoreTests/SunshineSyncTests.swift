import XCTest
@testable import MoonRiseCore

final class SunshineSyncTests: XCTestCase {
    /// 主 conf 目标键值含 sunshine_name（屏名），Moonlight 端对外显示该名。
    func testMainConfTargetValuesContainSunshineName() {
        var config = AppConfig()
        config.sunshine.disableAudioStreaming = false
        let values = SunshineSync.targetValues(outputName: 3, displayName: "Moon 1", config: config)
        XCTAssertEqual(values["sunshine_name"], "Moon 1")
        XCTAssertEqual(values["output_name"], "3")
        XCTAssertEqual(values["stream_audio"], "enabled")
    }

    func testMainConfTargetValuesRespectAudioSwitch() {
        var config = AppConfig()
        config.sunshine.disableAudioStreaming = true
        let values = SunshineSync.targetValues(outputName: 3, displayName: "Moon 1", config: config)
        XCTAssertEqual(values["stream_audio"], "disabled")
    }
}
