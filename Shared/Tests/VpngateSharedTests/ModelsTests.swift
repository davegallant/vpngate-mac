import XCTest
@testable import VpngateShared

final class ModelsTests: XCTestCase {
    func testServerCodableRoundTrip() throws {
        let server = Server(
            hostName: "public-vpn-1.example.com",
            countryLong: "Japan",
            countryShort: "JP",
            score: 12345,
            ipAddr: "1.2.3.4",
            openVpnConfigDataBase64: "c29tZS1jb25maWc=",
            ping: "42"
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        XCTAssertEqual(decoded, server)
    }

    func testConnectionStateCodableRoundTrip() throws {
        let state = ConnectionState(
            phase: .connected,
            hostName: "public-vpn-1.example.com",
            ipAddr: "1.2.3.4",
            countryLong: "Japan",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastError: nil
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ConnectionState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertNil(decoded.lastError)
    }

    func testLogLineCodableRoundTrip() throws {
        let line = LogLine(text: "Initialization Sequence Completed", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(LogLine.self, from: data)
        XCTAssertEqual(decoded, line)
    }

    func testHelperOperationErrorCodableRoundTrip() throws {
        let err = HelperOperationError(code: "openvpnNotFound", message: "openvpn not found", logTail: ["line1", "line2"])
        let data = try JSONEncoder().encode(err)
        let decoded = try JSONDecoder().decode(HelperOperationError.self, from: data)
        XCTAssertEqual(decoded, err)
    }

    func testConnectionPhaseBlockedRoundTrip() throws {
        XCTAssertEqual(ConnectionPhase.blocked.rawValue, "blocked")
        let data = try JSONEncoder().encode(ConnectionPhase.blocked)
        let decoded = try JSONDecoder().decode(ConnectionPhase.self, from: data)
        XCTAssertEqual(decoded, .blocked)
    }
}
