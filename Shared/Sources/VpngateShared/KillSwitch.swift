import Foundation

/// One `remote` entry from an OpenVPN config: the server/port/proto the
/// kill switch must keep reachable so the tunnel's own handshake can't be
/// blocked by its own pf rules.
public struct RemoteEndpoint: Codable, Equatable {
    public var ip: String
    public var port: Int
    public var proto: String

    public init(ip: String, port: Int, proto: String) {
        self.ip = ip
        self.port = port
        self.proto = proto
    }
}

/// Extracts `remote <ip> [port] [proto]` lines from a decoded `.ovpn`
/// config file's text, so the kill switch knows what to exempt before
/// `openvpn` even starts. A config may list multiple `remote` lines
/// (fallback servers); all of them are returned, in file order.
public enum OpenVPNConfigParser {
    private static let defaultPort = 1194
    private static let defaultProto = "udp"

    public static func parseRemotes(configText: String) -> [RemoteEndpoint] {
        var remotes: [RemoteEndpoint] = []
        for rawLine in configText.split(separator: "\n") {
            let tokens = rawLine.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard tokens.first == "remote", tokens.count >= 2 else { continue }
            let ip = tokens[1]
            let port = tokens.count >= 3 ? (Int(tokens[2]) ?? defaultPort) : defaultPort
            let proto = tokens.count >= 4 ? tokens[3].lowercased() : defaultProto
            remotes.append(RemoteEndpoint(ip: ip, port: port, proto: proto))
        }
        return remotes
    }
}

/// Builds the pf ruleset text loaded into the `com.apple/250.vpngate`
/// anchor. Pure string generation -- no `pfctl` invocation here, so it's
/// fully unit-testable without root.
public enum KillSwitchRules {
    /// Private/link-local ranges kept reachable so LAN devices (printers,
    /// AirPlay, local SSH) keep working while the kill switch blocks
    /// everything else.
    private static let privateRanges = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
    ]

    /// - Parameters:
    ///   - allowedRemotes: the OpenVPN server(s) traffic must reach to
    ///     complete the handshake, independent of the tunnel interface.
    ///   - tunnelInterface: the utun interface name once known (nil while
    ///     still connecting, before the interface has been detected).
    public static func pfRules(allowedRemotes: [RemoteEndpoint], tunnelInterface: String?) -> String {
        var lines: [String] = []
        lines.append("pass out quick on lo0 all keep state")
        for range in privateRanges {
            lines.append("pass out quick inet from any to \(range) keep state")
        }
        for remote in allowedRemotes {
            lines.append("pass out quick proto \(remote.proto) from any to \(remote.ip) port \(remote.port) keep state")
        }
        if let tunnelInterface {
            lines.append("pass out quick on \(tunnelInterface) keep state")
        }
        lines.append("block drop out all")
        return lines.joined(separator: "\n") + "\n"
    }
}
