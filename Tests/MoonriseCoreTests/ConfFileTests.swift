import XCTest
@testable import MoonriseCore

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
