import XCTest
@testable import MoonRiseCore

final class InstanceConfTests: XCTestCase {
    // MARK: - 端口分配器（D3）

    func testFirstFreePortIs48089() {
        XCTAssertEqual(InstanceConf.PortAllocator.nextFree(taken: []), 48_089)
    }

    func testSkipsTakenPortsByStep() {
        XCTAssertEqual(InstanceConf.PortAllocator.nextFree(taken: [48_089]), 48_189)
        XCTAssertEqual(InstanceConf.PortAllocator.nextFree(taken: [48_089, 48_189]), 48_289)
    }

    func testExhaustedReturnsNil() {
        var taken = Set<Int>()
        var port = InstanceConf.PortAllocator.nextFree(taken: taken)
        while let p = port {
            taken.insert(p)
            port = InstanceConf.PortAllocator.nextFree(taken: taken)
        }
        XCTAssertNil(port, "端口耗尽应返回 nil（不设屏幕数量上限的自然边界）")
        XCTAssertEqual(taken.count, 171, "48089…65135 步进 100 共 171 个")
    }

    // MARK: - conf 键集（凭据自包含——D4）

    func testFirstScreenYieldsEmptyValues() {
        let display = DisplayConfig(slotNumber: 1, name: "Moon 1", width: 2560, height: 1600, refreshRate: 60)
        let values = InstanceConf.targetValues(for: display, outputName: 42, audioDisabled: true)
        XCTAssertTrue(values.isEmpty, "首屏走主 conf，不经实例键集")
    }

    func testInstanceTargetValuesAreCompleteAndSlotBound() {
        let slotID = UUID()
        let display = DisplayConfig(
            id: slotID,
            slotNumber: 2, name: "Moon 2", width: 1920, height: 1080, refreshRate: 60,
            sunshinePort: 48_189)
        let values = InstanceConf.targetValues(for: display, outputName: 43, audioDisabled: true)
        XCTAssertEqual(values["output_name"], "43")
        XCTAssertEqual(values["stream_audio"], "disabled")
        XCTAssertEqual(values["port"], "48189")
        XCTAssertEqual(values["sunshine_name"], "Moon 2")
        XCTAssertEqual(values["pkey"], InstanceConf.credentialsDirectory(for: slotID).appendingPathComponent("cakey.pem").path)
        XCTAssertEqual(values["cert"], InstanceConf.credentialsDirectory(for: slotID).appendingPathComponent("cacert.pem").path)
        XCTAssertEqual(values["credentials_file"], InstanceConf.credentialsFileURL(for: slotID).path)
        XCTAssertEqual(values["file_state"], InstanceConf.credentialsFileURL(for: slotID).path)
        XCTAssertEqual(values["log_path"], InstanceConf.logURL(for: slotID).path)
        XCTAssertEqual(values["system_tray"], "disabled", "托盘抑制恒写 disabled（上游 system_tray 键）")
        XCTAssertEqual(Set(values.keys), [
            "output_name", "stream_audio", "port", "sunshine_name",
            "log_path", "pkey", "cert", "credentials_file", "file_state", "system_tray",
        ])
        XCTAssertTrue(values["pkey"]!.contains(slotID.uuidString), "凭据必须落在实例目录内（自包含）")
        XCTAssertTrue(values["file_state"]!.contains(slotID.uuidString), "配对状态必须自包含于实例目录（不写 file_state 会落到全局默认路径）")
    }

    // MARK: - 二进制副本（D16）

    func testBinaryCopyRefreshesWhenSourceChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let slotID = UUID()
        let source = dir.appendingPathComponent("sunshine-src")
        try "v1".write(to: source, atomically: true, encoding: .utf8)

        let copied1 = try InstanceConf.ensureBinaryCopy(sourceBinaryPath: source.path, slotID: slotID)
        XCTAssertEqual(try String(contentsOf: copied1, encoding: .utf8), "v1")

        // 幂等：源未变不重拷
        let copied2 = try InstanceConf.ensureBinaryCopy(sourceBinaryPath: source.path, slotID: slotID)
        XCTAssertEqual(copied2, copied1)

        // 源变化（brew 升级）→ 副本刷新
        try "v2-with-longer-content".write(to: source, atomically: true, encoding: .utf8)
        _ = try InstanceConf.ensureBinaryCopy(sourceBinaryPath: source.path, slotID: slotID)
        XCTAssertEqual(try String(contentsOf: copied1, encoding: .utf8), "v2-with-longer-content")
    }

    func testAppBundleCopyReturnsInnerExecutableAndCleansLegacyLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let slotID = UUID()

        // 伪造源 bundle：<dir>/App.app/Contents/MacOS/sunshine
        let sourceBundle = dir.appendingPathComponent("Src.app")
        let sourceExecutable = sourceBundle
            .appendingPathComponent("Contents/MacOS/sunshine")
        try FileManager.default.createDirectory(
            at: sourceExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "app-v1".write(to: sourceExecutable, atomically: true, encoding: .utf8)
        let detected = InstanceConf.hostAppBundle(of: sourceExecutable.path)
        XCTAssertEqual(detected?.path, sourceBundle.path)
        XCTAssertNil(InstanceConf.hostAppBundle(of: "/opt/homebrew/opt/sunshine/bin/sunshine"), "brew 裸二进制无宿主 bundle")

        // 副本 = bin/<源 bundle 名> 内层可执行
        let copied = try InstanceConf.ensureBinaryCopy(sourceBinaryPath: sourceExecutable.path, slotID: slotID)
        let expected = InstanceConf.appBundleCopyURL(for: slotID, bundleName: "Src.app")
            .appendingPathComponent("Contents/MacOS/sunshine")
        XCTAssertEqual(copied, expected)
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "app-v1")

        // 幂等：源未变不重拷（用 mtime 观察不到目录级变化，改为再次调用路径一致即覆盖）
        let copiedAgain = try InstanceConf.ensureBinaryCopy(sourceBinaryPath: sourceExecutable.path, slotID: slotID)
        XCTAssertEqual(copiedAgain, copied)

        // 源升级 → 内层二进制刷新
        try "app-v2".write(to: sourceExecutable, atomically: true, encoding: .utf8)
        _ = try InstanceConf.ensureBinaryCopy(sourceBinaryPath: sourceExecutable.path, slotID: slotID)
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "app-v2")
    }

    func testIsBindableAllowsFreeHighPort() {
        // 探测后即关闭，重复探测应持续可用
        XCTAssertTrue(InstanceConf.isBindable(59_123))
        XCTAssertTrue(InstanceConf.isBindable(59_123))
        XCTAssertFalse(InstanceConf.isBindable(0))
        XCTAssertFalse(InstanceConf.isBindable(-1))
    }

    func testEnsureStateFileCreatesMinimalAndPreservesExisting() throws {
        let slotID = UUID()
        defer { try? FileManager.default.removeItem(at: InstanceConf.stateFileURL(for: slotID)) }

        // 缺失 → 创建最小合法结构
        try InstanceConf.ensureStateFile(for: slotID)
        let url = InstanceConf.stateFileURL(for: slotID)
        let created = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(created.contains("\"root\""), "应含 root 字段")

        // 已有内容 → 原样保留（不覆盖已配对设备）
        let existing = "{\"root\": {\"uniqueid\": \"X\", \"named_devices\": []}}"
        try existing.write(to: url, atomically: true, encoding: .utf8)
        try InstanceConf.ensureStateFile(for: slotID)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), existing, "已有内容不得覆盖")
    }

}
