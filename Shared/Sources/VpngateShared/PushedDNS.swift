import Foundation

/// Extracts DNS servers pushed by an OpenVPN server, so the helper can point
/// the active network service's resolver at them once connected. Pure
/// string parsing -- no networksetup/system calls here -- so it's fully
/// unit-testable without root.
public enum PushedDNS {
    /// Parses a single log line like:
    /// `PUSH: Received control message: 'PUSH_REPLY,ping 3,ping-restart 10,ifconfig 10.234.15.53 10.234.15.54,dhcp-option DNS 10.234.254.254,dhcp-option DNS 8.8.8.8,route-gateway 10.234.15.54,redirect-gateway def1'`
    /// into its pushed `dhcp-option DNS <ip>` server IPs, in the order OpenVPN
    /// listed them. Returns an empty array if the server pushed no DNS
    /// servers or the line isn't a PUSH_REPLY at all.
    public static func parseServers(fromPushReplyLine line: String) -> [String] {
        line.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init) }
            .filter { $0.count >= 3 && $0[0] == "dhcp-option" && $0[1] == "DNS" }
            .map { $0[2] }
    }
}
