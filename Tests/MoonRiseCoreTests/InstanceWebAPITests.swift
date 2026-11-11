import XCTest
@testable import MoonRiseCore

final class InstanceWebAPITests: XCTestCase {
    func testBasicAuthHeader() {
        let header = InstanceWebAPI.basicAuthHeader(InstanceWebAPI.Credentials(username: "u", password: "p"))
        XCTAssertEqual(header, "Basic " + Data("u:p".utf8).base64EncodedString())
    }

    func testParsePendingPairings() {
        let json = #"{"pairings": [{"id": "abc123", "name": "iPad-Pro", "address": "192.168.200.88"}]}"#
        let pairings = InstanceWebAPI.parsePendingPairings(Data(json.utf8))
        XCTAssertEqual(pairings.count, 1)
        XCTAssertEqual(pairings[0].id, "abc123")
        XCTAssertEqual(pairings[0].name, "iPad-Pro")
        XCTAssertEqual(pairings[0].address, "192.168.200.88")
    }

    func testParsePendingPairingsToleratesMalformed() {
        XCTAssertTrue(InstanceWebAPI.parsePendingPairings(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(InstanceWebAPI.parsePendingPairings(Data(#"{"pairings": null}"#.utf8)).isEmpty)
    }

    func testIsValidPin() {
        XCTAssertTrue(InstanceWebAPI.isValidPin("0947"))
        XCTAssertFalse(InstanceWebAPI.isValidPin("094"))
        XCTAssertFalse(InstanceWebAPI.isValidPin("09a7"))
        XCTAssertFalse(InstanceWebAPI.isValidPin(""))
    }

    func testGenerateCredentialsNonEmpty() {
        let credentials = InstanceWebAPI.generateCredentials()
        XCTAssertFalse(credentials.username.isEmpty)
        XCTAssertFalse(credentials.password.isEmpty)
        XCTAssertNotEqual(credentials.username, InstanceWebAPI.generateCredentials().username)
    }

    func testCredentialsFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("webui.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = InstanceWebAPI.Credentials(username: "moonrise-abc", password: "secret")

        XCTAssertNil(InstanceWebAPI.loadCredentials(from: url))
        try InstanceWebAPI.saveCredentials(credentials, to: url)
        XCTAssertEqual(InstanceWebAPI.loadCredentials(from: url), credentials)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int) ?? 0o644, 0o600, "凭据文件应为 0600")
    }

    func testParseClientNames() {
        let json = #"{"named_certs": [{"name": "roth", "uuid": "u1", "enabled": true}, {"name": "mac", "uuid": "u2", "enabled": false}], "status": true}"#
        XCTAssertEqual(InstanceWebAPI.parseClientNames(Data(json.utf8)), ["roth", "mac"])
        XCTAssertTrue(InstanceWebAPI.parseClientNames(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(InstanceWebAPI.parseClientNames(Data(#"{"named_certs": []}"#.utf8)).isEmpty)
    }

    func testWebPortIsBasePlusOne() {
        XCTAssertEqual(InstanceWebAPI.webPort(base: 48089), 48090)
    }
}
