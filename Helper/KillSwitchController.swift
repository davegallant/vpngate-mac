import Foundation
import VpngateShared

enum KillSwitchError: Error, CustomStringConvertible {
    case pfctlFailed(String)
    case anchorHookMissing

    var description: String {
        switch self {
        case .pfctlFailed(let detail): return "pfctl failed: \(detail)"
        case .anchorHookMissing:
            return "main pf ruleset has no com.apple/* anchor hook; kill switch rules would never be evaluated"
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
    private let pfConfPath = "/etc/pf.conf"
    private let anchorHookMarker = "\"com.apple/*\""

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
    /// `extendWithTunnelInterface`). Throws if pf can't be enabled, the
    /// main ruleset has no anchor hook for our rules to hang off of, or
    /// the rules can't be loaded -- callers must treat that as fatal to
    /// the connection attempt rather than proceeding unprotected.
    func engage(allowedRemotes: [RemoteEndpoint]) throws {
        try enablePf()
        try ensureAnchorHookPresent()
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

    /// `pfctl -e` only flips pf's enabled flag -- it never loads
    /// `/etc/pf.conf`, so on its own it says nothing about whether the
    /// `anchor "com.apple/*"` hook our sub-anchor relies on is actually
    /// wired into the main ruleset. If pf's main ruleset was ever flushed
    /// (observed after sleep/wake), our rules load into the named anchor
    /// fine and `pfctl -a ... -s rules` happily prints them back, but
    /// they're never evaluated against real traffic -- a silent, total
    /// bypass. Restore Apple's stock file (never a custom one) only if the
    /// hook is confirmed missing, so any other tool's main-ruleset rules
    /// are left alone in the common case.
    private func ensureAnchorHookPresent() throws {
        if try mainRulesetContainsAnchorHook() {
            return
        }
        _ = try? runPfctl(["-f", pfConfPath])
        guard try mainRulesetContainsAnchorHook() else {
            throw KillSwitchError.anchorHookMissing
        }
    }

    private func mainRulesetContainsAnchorHook() throws -> Bool {
        let output = try runPfctl(["-s", "rules"])
        return output.contains(anchorHookMarker)
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

    /// Returns stdout on success (used by `-s rules`); on failure throws
    /// with stderr, which is what `enablePf()`'s "already enabled" check
    /// matches against.
    @discardableResult
    private func runPfctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pfctlPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw KillSwitchError.pfctlFailed(String(data: errData, encoding: .utf8) ?? "unknown pfctl error")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
