import XCTest
@testable import VpngateShared

final class PushedDNSTests: XCTestCase {
    func testParseServers_realPushReplyLine() {
        let line = "PUSH: Received control message: 'PUSH_REPLY,ping 3,ping-restart 10,ifconfig 10.234.15.53 10.234.15.54,dhcp-option DNS 10.234.254.254,dhcp-option DNS 8.8.8.8,route-gateway 10.234.15.54,redirect-gateway def1'"
        XCTAssertEqual(PushedDNS.parseServers(fromPushReplyLine: line), ["10.234.254.254", "8.8.8.8"])
    }

    func testParseServers_noDNSPushed() {
        let line = "PUSH: Received control message: 'PUSH_REPLY,ping 3,ping-restart 10,ifconfig 10.234.15.53 10.234.15.54,route-gateway 10.234.15.54,redirect-gateway def1'"
        XCTAssertEqual(PushedDNS.parseServers(fromPushReplyLine: line), [])
    }

    func testParseServers_notAPushReplyLine() {
        XCTAssertEqual(PushedDNS.parseServers(fromPushReplyLine: "Opened utun device utun20"), [])
    }

    func testParseServers_singleDNSServer() {
        let line = "PUSH: Received control message: 'PUSH_REPLY,dhcp-option DNS 8.8.8.8,route-gateway 10.234.15.54'"
        XCTAssertEqual(PushedDNS.parseServers(fromPushReplyLine: line), ["8.8.8.8"])
    }
}
