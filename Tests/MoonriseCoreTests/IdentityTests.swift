import XCTest
@testable import MoonriseCore

final class IdentityTests: XCTestCase {
    func testSerialIsDeterministic() {
        let a = DisplayIdentity.derivedSerial(name: "Sunshine Ext", width: 2560, height: 1600, salt: 0)
        let b = DisplayIdentity.derivedSerial(name: "Sunshine Ext", width: 2560, height: 1600, salt: 0)
        XCTAssertEqual(a, b)
    }

    func testSerialChangesWithSizeAndSalt() {
        let base = DisplayIdentity.derivedSerial(name: "Sunshine Ext", width: 2560, height: 1600, salt: 0)
        let otherSize = DisplayIdentity.derivedSerial(name: "Sunshine Ext", width: 1920, height: 1200, salt: 0)
        let salted = DisplayIdentity.derivedSerial(name: "Sunshine Ext", width: 2560, height: 1600, salt: DisplayIdentity.retrySalt)
        XCTAssertNotEqual(base, otherSize)
        XCTAssertNotEqual(base, salted)
    }

    func testSerialNeverZero() {
        for salt in [UInt32(0), 1, 42] {
            XCTAssertNotEqual(DisplayIdentity.derivedSerial(name: "x", width: 64, height: 64, salt: salt), 0)
        }
    }

    func testKnownVectorMatchesReferenceImplementation() {
        // 与 spike 实测一致：FNV-1a("Sunshine Ext Spike|2560x1600|0") = 1495120523
        XCTAssertEqual(DisplayIdentity.derivedSerial(name: "Sunshine Ext Spike", width: 2560, height: 1600, salt: 0), 1_495_120_523)
    }

    func testIdentityFields() {
        let spec = DisplaySpec.default
        XCTAssertEqual(spec.identity.vendorID, 0x7365)
        XCTAssertEqual(spec.identity.productID, 0x6578)
    }
}
