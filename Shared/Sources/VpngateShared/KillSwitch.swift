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
        // `\.isNewline` (not `separator: "\n"`) is required: real .ovpn
        // files are CRLF-terminated, and Swift's `Character` treats
        // "\r\n" as a single grapheme cluster distinct from a bare "\n"
        // -- splitting on "\n" alone never matches it, so the whole file
        // is seen as one non-matching "line" and zero remotes are found.
        let lines = configText.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        }

        // OpenVPN configs commonly declare the protocol once via a
        // top-level `proto tcp`/`proto udp` directive rather than on
        // each `remote` line -- that's the format VPNGate itself uses.
        // A later `proto` line wins, matching OpenVPN's own "last one
        // set applies" config semantics.
        var configuredProto = defaultProto
        for tokens in lines where tokens.first == "proto" && tokens.count >= 2 {
            configuredProto = normalizeProto(tokens[1])
        }

        var remotes: [RemoteEndpoint] = []
        for tokens in lines where tokens.first == "remote" && tokens.count >= 2 {
            let ip = tokens[1]
            let port = tokens.count >= 3 ? (Int(tokens[2]) ?? defaultPort) : defaultPort
            let proto = tokens.count >= 4 ? normalizeProto(tokens[3]) : configuredProto
            remotes.append(RemoteEndpoint(ip: ip, port: port, proto: proto))
        }
        return remotes
    }

    /// OpenVPN accepts protocol values like `tcp-client`/`tcp-server` in
    /// addition to plain `tcp`/`udp`; pf only understands the plain form.
    private static func normalizeProto(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("tcp") { return "tcp" }
        if lower.hasPrefix("udp") { return "udp" }
        return lower
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
        // Deliberately no "out" direction restriction here (unlike every
        // other rule below): a loopback packet is filtered twice --
        // once leaving the sender, again arriving at the receiver, both
        // on lo0 -- and an out-only rule leaves that second, inbound
        // pass through pf uncovered. That gap reproduced as a real,
        // measured effect (~18% vs ~88% success dialing openvpn's own
        // loopback management port with the kill switch on vs off) rather
        // than a theoretical concern.
        lines.append("pass quick on lo0 all keep state")
        for range in privateRanges {
            lines.append("pass out quick inet from any to \(range) keep state")
        }
        for remote in allowedRemotes {
            lines.append("pass out quick proto \(remote.proto) from any to \(remote.ip) port \(remote.port) keep state")
        }
        if let tunnelInterface {
            lines.append("pass out quick on \(tunnelInterface) keep state")
        }
        // `quick` here is required, not cosmetic: under the `com.apple/*`
        // wildcard anchor, pf evaluates every matching anchor as one
        // chained ruleset. A bare (non-quick) `block` only records a
        // block decision and keeps evaluating -- a later anchor, or the
        // eventual default-pass fallthrough if nothing else matches,
        // can silently override it. Without `quick` this catch-all
        // blocks nothing.
        lines.append("block drop out quick all")
        return lines.joined(separator: "\n") + "\n"
    }
}
