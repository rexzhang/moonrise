import XCTest
@testable import MoonRiseCore

final class ConfigStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testMutatePersistsAcrossInstances() {
        let defaults = freshDefaults()
        let store = ConfigStore(defaults: defaults)
        store.mutate { $0.keepHostScaling = false }
        store.mutate { $0.sunshine.disableAudioStreaming = false }

        let reopened = ConfigStore(defaults: defaults)
        XCTAssertFalse(reopened.config.keepHostScaling)
        XCTAssertFalse(reopened.config.sunshine.disableAudioStreaming)
        XCTAssertEqual(reopened.config.sunshine.selectedVersion, "latest")
    }

    func testSelectedVersionMutation() {
        let defaults = freshDefaults()
        let store = ConfigStore(defaults: defaults)
        store.mutate { $0.sunshine.selectedVersion = "v2026.1112.40957" }
        XCTAssertEqual(store.config.sunshine.selectedVersion, "v2026.1112.40957")
    }

    func testLegacyFileImportArchivesAndPopulatesBlob() throws {
        let defaults = freshDefaults()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let legacy = dir.appendingPathComponent("config.json")
        var sample = AppConfig()
        sample.sunshine.selectedVersion = "v2026.1112.40957"
        try JSONEncoder().encode(sample).write(to: legacy)

        let store = ConfigStore(defaults: defaults, legacyURL: legacy)
        XCTAssertEqual(store.config.sunshine.selectedVersion, "v2026.1112.40957")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "旧文件已改名归档")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json.imported").path))
        // blob 已落库：再次打开不依赖旧文件
        let reopened = ConfigStore(defaults: defaults, legacyURL: legacy)
        XCTAssertEqual(reopened.config.sunshine.selectedVersion, "v2026.1112.40957")
    }

    func testCorruptBlobFallsBackToDefaults() {
        let defaults = freshDefaults()
        defaults.set("不是 JSON".data(using: .utf8)!, forKey: "appConfig")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        let store = ConfigStore(defaults: defaults, legacyURL: missing)
        XCTAssertEqual(store.config, .standard)
    }
}
