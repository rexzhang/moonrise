import XCTest
@testable import MoonRiseCore

final class IdentityTests: XCTestCase {
    func testSerialIsDeterministic() {
        let a = DisplayIdentity.derivedSerial(name: "Moon", width: 2560, height: 1600, salt: 0)
        let b = DisplayIdentity.derivedSerial(name: "Moon", width: 2560, height: 1600, salt: 0)
        XCTAssertEqual(a, b)
    }

    func testSerialChangesWithSizeAndSalt() {
        let base = DisplayIdentity.derivedSerial(name: "Moon", width: 2560, height: 1600, salt: 0)
        let otherSize = DisplayIdentity.derivedSerial(name: "Moon", width: 1920, height: 1200, salt: 0)
        let salted = DisplayIdentity.derivedSerial(name: "Moon", width: 2560, height: 1600, salt: DisplayIdentity.retrySalt)
        XCTAssertNotEqual(base, otherSize)
        XCTAssertNotEqual(base, salted)
    }

    func testSerialNeverZero() {
        for salt in [UInt32(0), 1, 42] {
            XCTAssertNotEqual(DisplayIdentity.derivedSerial(name: "x", width: 64, height: 64, salt: salt), 0)
        }
    }

    func testKnownVectorMatchesReferenceImplementation() {
        // 校验向量（独立实现计算）：FNV-1a("Moon|2560x1600|0") = 197405638
        XCTAssertEqual(DisplayIdentity.derivedSerial(name: "Moon", width: 2560, height: 1600, salt: 0), 197_405_638)
    }

    func testDistinctNamesYieldDistinctSerialsForMultiScreen() {
        // 多屏身份唯一性：同名同尺寸会撞身份，Moon N 自动命名天然区分
        let a = DisplayIdentity.derivedSerial(name: "Moon 1", width: 2560, height: 1600, salt: 0)
        let b = DisplayIdentity.derivedSerial(name: "Moon 2", width: 2560, height: 1600, salt: 0)
        XCTAssertNotEqual(a, b)
    }

    func testIdentityFields() {
        let spec = DisplaySpec.default
        XCTAssertEqual(spec.identity.vendorID, 0x6D6F)
        XCTAssertEqual(spec.identity.productID, 0x6F6E)
    }
}
