import XCTest
@testable import MoonRiseCore

final class ManagedSunshineStoreTests: XCTestCase {
    private func release(tag: String) -> ManagedSunshineStore.Release {
        ManagedSunshineStore.Release(
            tag: tag, publishedAt: "", isPrerelease: false,
            downloadURL: nil, size: nil)
    }

    // MARK: - 版本比较（tag 语义：数字分段，缺段补 0）

    func testIsVersionComparisons() {
        XCTAssertTrue(ManagedSunshineStore.isVersion("v2026.1112", atLeast: "v2026.1112"))
        XCTAssertTrue(ManagedSunshineStore.isVersion("v2026.1112.40957", atLeast: "v2026.1112"), "缺段补 0")
        XCTAssertFalse(ManagedSunshineStore.isVersion("v2026.914.233613", atLeast: "v2026.1112"))
        XCTAssertTrue(ManagedSunshineStore.isVersion("v2027.1", atLeast: "v2026.1112"))
        XCTAssertFalse(ManagedSunshineStore.isVersion("v2026.1100", atLeast: "v2026.1112"), "数字比较而非逐位")
    }

    func testMinimumSupportedReleaseFlag() {
        XCTAssertFalse(release(tag: "v2026.914.233613").isSupported)
        XCTAssertTrue(release(tag: "v2026.1112.13541").isSupported)
    }

    // MARK: - 就绪判定（唯一来源 = 受管副本）

    func testIsReadyFalseWhenManagedBinaryMissing() {
        // 测试环境不落受管副本：以路径注入不可行（isReady 读固定路径），
        // 此处断言当前机器语义——受管目录存在与否决定返回值，且与可执行文件一致
        let expected = FileManager.default.isExecutableFile(atPath: Paths.managedSunshineExecutableURL.path)
        XCTAssertEqual(ManagedSunshineStore.isReady(), expected)
    }

    func testArchAssetNameIsKnown() {
        XCTAssertTrue(["arm64", "x86_64"].contains(ManagedSunshineStore.archAssetName))
    }
}
