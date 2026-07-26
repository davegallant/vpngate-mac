import Foundation
import VpngateShared

enum KillSwitchError: Error, CustomStringConvertible {
    case pfctlFailed(String)

    var description: String {
        switch self {
        case .pfctlFailed(let detail): return "pfctl failed: \(detail)"
        }
    }
}

/// Owns the lifecycle of the pf anchor used as a hard kill switch: while
/// armed, only loopback, LAN ranges, the VPN server(s), and (once known)
/// the tunnel interface can send traffic out -- everything else is
/// dropped. Uses macOS's stock `anchor "com.apple/*"` wildcard already
/// present in /etc/pf.conf, so /etc/pf.conf itself is never touched and
/// this coexists with Application Firewall, Docker Desktop, etc., each of
/// which owns its own sub-anchor under the same wildcard.
final class KillSwitchController {
    private let anchorName = "com.apple/250.vpngate"
    private let pfctlPath = "/sbin/pfctl"

    /// Called once when the helper daemon launches (see
    /// `OpenVPNSupervisor.init()`). The helper has no persisted state
    /// across restarts, so if it crashed while armed -- or the Mac
    /// rebooted -- stale rules from a previous run could otherwise
    /// strand the network with no recovery path short of manual `pfctl`
    /// surgery. Best-effort: never throws, since there's nothing
    /// meaningful to roll back to if the flush itself fails.
    func flushStaleRulesOnStartup() {
        _ = try? runPfctl(["-a", anchorName, "-F", "all"])
    }

    /// Arms the kill switch for the given remotes, with no tunnel
    /// interface exception yet (added later via
    /// `extendWithTunnelInterface`). Throws if pf can't be enabled or the
    /// rules can't be loaded -- callers must treat that as fatal to the
    /// connection attempt rather than proceeding unprotected.
    func engage(allowedRemotes: [RemoteEndpoint]) throws {
        try enablePf()
        try loadRules(KillSwitchRules.pfRules(allowedRemotes: allowedRemotes, tunnelInterface: nil))
    }

    /// Reloads the anchor to additionally allow the now-known tunnel
    /// interface. Replaces the whole ruleset (pf anchors don't support
    /// incremental appends), so `allowedRemotes` must be passed again.
    func extendWithTunnelInterface(_ interfaceName: String, allowedRemotes: [RemoteEndpoint]) throws {
        try loadRules(KillSwitchRules.pfRules(allowedRemotes: allowedRemotes, tunnelInterface: interfaceName))
    }

    /// Flushes the anchor back to empty, restoring normal routing.
    func disengage() {
        _ = try? runPfctl(["-a", anchorName, "-F", "all"])
    }

    private func enablePf() throws {
        do {
            _ = try runPfctl(["-e"])
        } catch KillSwitchError.pfctlFailed(let detail) where detail.localizedCaseInsensitiveContains("already enabled") {
            // Not a real failure -- pf was already on (e.g. Application
            // Firewall or another tool enabled it first).
        }
    }

    private func loadRules(_ rulesText: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pfctlPath)
        process.arguments = ["-a", anchorName, "-f", "-"]
        let stdin = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdin
        process.standardError = stderrPipe
        try process.run()
        stdin.fileHandleForWriting.write(Data(rulesText.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            throw KillSwitchError.pfctlFailed(String(data: errData, encoding: .utf8) ?? "unknown pfctl error")
        }
    }

    @discardableResult
    private func runPfctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pfctlPath)
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw KillSwitchError.pfctlFailed(errText)
        }
        return errText
    }
}
