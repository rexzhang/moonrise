import XCTest
@testable import MoonRiseCore

final class StreamStateMonitorTests: XCTestCase {
    // MARK: - 标记行状态机（纯函数）

    func testSessionStartMarker() {
        XCTAssertTrue(StreamStateMonitor.apply(
            line: "[2026-11-10 14:40:16.700]: Info: New streaming session started [active sessions: 1]",
            to: false))
    }

    func testDisconnectMarker() {
        XCTAssertFalse(StreamStateMonitor.apply(
            line: "[2026-11-10 14:12:23.613]: Info: CLIENT DISCONNECTED",
            to: true))
    }

    func testUnrelatedLinesKeepState() {
        XCTAssertTrue(StreamStateMonitor.apply(line: "Info: Creating encoder [h264_videotoolbox]", to: true))
        XCTAssertFalse(StreamStateMonitor.apply(line: "Info: Starting main loop", to: false))
    }

    // MARK: - 文件尾随

    func testTrackFromExistingLogInfersOngoingSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("sunshine-ab.log")
        try """
        Info: Starting main loop
        Info: New streaming session started [active sessions: 1]
        Info: CLIENT CONNECTED
        """.write(to: log, atomically: true, encoding: .utf8)

        let monitor = StreamStateMonitor()
        let slotID = UUID()
        monitor.track(slotID: slotID, logURL: log)
        monitor.pollNow()
        XCTAssertTrue(monitor.isStreaming(slotID: slotID), "重启 App 时日志里最后标记是会话开始且无断连 → 应推断为串流中")
    }

    func testFollowsNewAppendedLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("sunshine-cd.log")
        try "Info: Starting main loop\n".write(to: log, atomically: true, encoding: .utf8)

        let monitor = StreamStateMonitor()
        var events: [(UUID, Bool)] = []
        monitor.onStreamingChanged = { slotID, streaming in events.append((slotID, streaming)) }
        let slotID = UUID()
        monitor.track(slotID: slotID, logURL: log)
        monitor.pollNow()
        XCTAssertFalse(monitor.isStreaming(slotID: slotID))

        // 追加会话开始（含半行边界场景：不带结尾换行）
        try "Info: New streaming session started".append(to: log)
        monitor.pollNow()
        XCTAssertFalse(monitor.isStreaming(slotID: slotID), "半行缓冲：未收尾的行不应立即生效")

        try "\n".append(to: log)
        monitor.pollNow()
        XCTAssertTrue(monitor.isStreaming(slotID: slotID))
        XCTAssertEqual(events.map(\.1), [true])
    }

    func testUnreachableLogKeepsState() {
        let monitor = StreamStateMonitor()
        let slotID = UUID()
        monitor.track(slotID: slotID, logURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.log"))
        monitor.pollNow()
        XCTAssertFalse(monitor.isStreaming(slotID: slotID), "日志不可达保持原状态（D12）")
    }
}

private extension String {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.utf8))
    }
}
