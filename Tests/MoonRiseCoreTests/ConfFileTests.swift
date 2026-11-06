import XCTest
@testable import MoonRiseCore

final class ConfFileTests: XCTestCase {
    func testAppendWhenKeyMissing() {
        let original = """
        # sunshine.conf
        port = 47989
        min_log_level = info
        """
        let (result, output) = ConfFile.setValue(in: original, key: "output_name", value: "30")
        XCTAssertEqual(result, .changed)
        XCTAssertTrue(output.hasSuffix("\noutput_name = 30\n"))
        XCTAssertTrue(output.contains("port = 47989"))
    }

    func testReplaceKeepsOtherLines() {
        let original = """
        # 注释
        output_name = 3
        min_log_level = info
        """
        let (result, output) = ConfFile.setValue(in: original, key: "output_name", value: "30")
        XCTAssertEqual(result, .changed)
        XCTAssertTrue(output.contains("output_name = 30"))
        XCTAssertFalse(output.contains("output_name = 3\nmin"), "旧值行应被替换")
        XCTAssertTrue(output.contains("# 注释"))
        XCTAssertTrue(output.contains("min_log_level = info"))
    }

    func testUnchangedWhenValueMatches() {
        let original = "output_name = 30\nmin_log_level = info\n"
        let (result, output) = ConfFile.setValue(in: original, key: "output_name", value: "30")
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(output, original)
    }

    func testSkipsCommentedKey() {
        let original = "# output_name = 3\n"
        let (result, output) = ConfFile.setValue(in: original, key: "output_name", value: "30")
        XCTAssertEqual(result, .changed)
        XCTAssertTrue(output.hasSuffix("# output_name = 3\noutput_name = 30\n"))
    }

    func testReadValue() {
        let text = "  # x\n  output_name =  42  \nport=1\n"
        XCTAssertEqual(ConfFile.readValue(in: text, key: "output_name"), "42")
        XCTAssertEqual(ConfFile.readValue(in: text, key: "port"), "1")
        XCTAssertNil(ConfFile.readValue(in: text, key: "missing"))
        XCTAssertNil(ConfFile.readValue(in: "# output_name = 3\n", key: "output_name"))
    }
}

final class SyncValuesTests: XCTestCase {
    func testMultiKeySyncIdempotentAndPartialChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let conf = dir.appendingPathComponent("sunshine.conf")
        try "locale = zh\n".write(to: conf, atomically: true, encoding: .utf8)

        // 首次：追加两个键
        XCTAssertEqual(try ConfFile.syncValues(configPath: conf.path, values: ["output_name": "43", "stream_audio": "disabled"]), .changed)
        let text1 = try String(contentsOf: conf, encoding: .utf8)
        XCTAssertTrue(text1.contains("output_name = 43"))
        XCTAssertTrue(text1.contains("stream_audio = disabled"))
        XCTAssertTrue(text1.contains("locale = zh"))

        // 幂等：相同值不写盘
        XCTAssertEqual(try ConfFile.syncValues(configPath: conf.path, values: ["output_name": "43", "stream_audio": "disabled"]), .unchanged)

        // 单键变化：仅改该键
        XCTAssertEqual(try ConfFile.syncValues(configPath: conf.path, values: ["output_name": "43", "stream_audio": "enabled"]), .changed)
        XCTAssertEqual(ConfFile.readValue(in: try String(contentsOf: conf, encoding: .utf8), key: "stream_audio"), "enabled")
        XCTAssertEqual(ConfFile.readValue(in: try String(contentsOf: conf, encoding: .utf8), key: "output_name"), "43")

        // 配置缺失报错
        let missing = dir.appendingPathComponent("nope.conf")
        XCTAssertThrowsError(try ConfFile.syncValues(configPath: missing.path, values: ["k": "v"]))
    }
}
