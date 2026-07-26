import XCTest
@testable import VpngateShared

final class KillSwitchTests: XCTestCase {
    // MARK: - OpenVPNConfigParser

    func testParseRemotes_singleRemoteWithPortAndProto() {
        let config = """
        client
        dev tun
        remote 203.0.113.5 1194 udp
        cipher AES-128-CBC
        """
        let remotes = OpenVPNConfigParser.parseRemotes(configText: config)
        XCTAssertEqual(remotes, [RemoteEndpoint(ip: "203.0.113.5", port: 1194, proto: "udp")])
    }

    func testParseRemotes_multipleRemotes() {
        let config = """
        remote 203.0.113.5 1194 udp
        remote 203.0.113.5 443 tcp
        """
        let remotes = OpenVPNConfigParser.parseRemotes(configText: config)
        XCTAssertEqual(remotes, [
            RemoteEndpoint(ip: "203.0.113.5", port: 1194, proto: "udp"),
            RemoteEndpoint(ip: "203.0.113.5", port: 443, proto: "tcp"),
        ])
    }

    func testParseRemotes_missingProtoDefaultsToUDP() {
        let remotes = OpenVPNConfigParser.parseRemotes(configText: "remote 203.0.113.5 1194")
        XCTAssertEqual(remotes, [RemoteEndpoint(ip: "203.0.113.5", port: 1194, proto: "udp")])
    }

    func testParseRemotes_missingPortDefaultsTo1194() {
        let remotes = OpenVPNConfigParser.parseRemotes(configText: "remote 203.0.113.5")
        XCTAssertEqual(remotes, [RemoteEndpoint(ip: "203.0.113.5", port: 1194, proto: "udp")])
    }

    func testParseRemotes_noRemoteLinesReturnsEmpty() {
        let config = "client\ndev tun\ncipher AES-128-CBC"
        XCTAssertEqual(OpenVPNConfigParser.parseRemotes(configText: config), [])
    }

    // MARK: - KillSwitchRules

    func testPfRules_withoutTunnelInterface() {
        let rules = KillSwitchRules.pfRules(
            allowedRemotes: [RemoteEndpoint(ip: "203.0.113.5", port: 1194, proto: "udp")],
            tunnelInterface: nil
        )
        XCTAssertEqual(rules, """
        pass out quick on lo0 all keep state
        pass out quick inet from any to 10.0.0.0/8 keep state
        pass out quick inet from any to 172.16.0.0/12 keep state
        pass out quick inet from any to 192.168.0.0/16 keep state
        pass out quick inet from any to 169.254.0.0/16 keep state
        pass out quick proto udp from any to 203.0.113.5 port 1194 keep state
        block drop out all

        """)
    }

    func testPfRules_withTunnelInterface() {
        let rules = KillSwitchRules.pfRules(
            allowedRemotes: [RemoteEndpoint(ip: "203.0.113.5", port: 1194, proto: "udp")],
            tunnelInterface: "utun3"
        )
        XCTAssertTrue(rules.contains("pass out quick on utun3 keep state\n"))
        XCTAssertTrue(rules.hasSuffix("block drop out all\n"))
    }

    func testPfRules_multipleRemotesAllExempted() {
        let rules = KillSwitchRules.pfRules(
            allowedRemotes: [
                RemoteEndpoint(ip: "203.0.113.5", port: 1194, proto: "udp"),
                RemoteEndpoint(ip: "203.0.113.5", port: 443, proto: "tcp"),
            ],
            tunnelInterface: nil
        )
        XCTAssertTrue(rules.contains("pass out quick proto udp from any to 203.0.113.5 port 1194 keep state\n"))
        XCTAssertTrue(rules.contains("pass out quick proto tcp from any to 203.0.113.5 port 443 keep state\n"))
    }
}
