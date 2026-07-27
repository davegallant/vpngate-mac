import Foundation
import VpngateShared

/// Owns a single openvpn subprocess and its management-interface
/// connection: starts openvpn, waits for CONNECTED, and reports state
/// changes / log lines via callbacks. One connection at a time, mirroring
/// pkg/daemon's supervisor in the Go CLI.
final class OpenVPNSupervisor {
    // External-install fallback paths, checked only if the bundled binary
    // (see `bundledOpenvpnPath`) isn't present -- kept for anyone pinning
    // their own openvpn build.
    private let fallbackOpenvpnPaths = [
        "/usr/local/bin/openvpn",
        "/opt/homebrew/bin/openvpn",
        "/usr/bin/openvpn",
        "/run/current-system/sw/bin/openvpn",
    ]
    private let logFileURL = URL(fileURLWithPath: "/Library/Application Support/Vpngate/daemon.log")

    private var process: Process?
    private var managementClient: ManagementClient?
    private let killSwitch = KillSwitchController()
    private var allowedRemotes: [RemoteEndpoint] = []
    private var killSwitchEnabled = false
    private var tunnelInterfaceArmed = false
    /// Set once openvpn's own log reports "Initialization Sequence
    /// Completed" -- i.e. the tunnel itself is up (TLS handshake done,
    /// routes installed), independent of whether our management-port
    /// control channel ever connects. Used by the mgmt-failure handler
    /// below: a control-channel dial failure after this point means we've
    /// lost the ability to *monitor*/*signal* the tunnel, not that the
    /// tunnel itself failed -- tearing down a working connection because
    /// of that would be strictly worse for the user than keeping it up
    /// without live state updates.
    private var tunnelInitialized = false
    private var isExplicitDisconnect = false
    private(set) var currentState = ConnectionState.disconnected

    var onStateChange: ((ConnectionState) -> Void)?
    var onLogLine: ((LogLine) -> Void)?

    init() {
        killSwitch.flushStaleRulesOnStartup()
    }

    // The helper daemon's own executable is embedded at
    // `VPNGate.app/Contents/Library/LaunchDaemons/...` -- `Bundle.main`
    // from inside the helper process resolves to that inner location, not
    // the outer .app, so the bundled openvpn (copied to
    // `VPNGate.app/Contents/Library/openvpn/openvpn`) has to be found by
    // walking up from the helper's own executable path instead.
    private func bundledOpenvpnPath() -> String? {
        var url = Bundle.main.bundleURL
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url.appendingPathComponent("Contents/Library/openvpn/openvpn").path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func resolveOpenvpnPath() -> String? {
        let candidates = [bundledOpenvpnPath()].compactMap { $0 } + fallbackOpenvpnPaths
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Best-effort append to the persistent daemon.log — failures here
    /// (e.g. directory doesn't exist yet on first run) must never take
    /// down the connection, so errors are silently swallowed after the
    /// one-time directory-creation attempt.
    private func persistLogLine(_ text: String) {
        try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = (text + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logFileURL)
        }
    }

    /// Writes to both the persisted daemon.log and the live "Vpngate Logs"
    /// window (`onLogLine`) -- unlike `persistLogLine` alone, which only
    /// hits the file. Used for our own diagnostic lines (management-client
    /// dial/read progress) rather than openvpn's own stdout/stderr, which
    /// is piped separately.
    private func log(_ text: String) {
        persistLogLine(text)
        onLogLine?(LogLine(text: text, timestamp: Date()))
    }

    /// `log(_:)` exposed for callers outside this type (HelperXPCService's
    /// own connect/cancel bookkeeping) so their diagnostic lines land in the
    /// same visible log stream instead of being invisible.
    func debugLog(_ text: String) {
        log(text)
    }

    func connect(to server: Server, killSwitchEnabled: Bool) async throws {
        guard let executablePath = resolveOpenvpnPath() else {
            throw HelperOperationError.openvpnNotFound()
        }
        log("using openvpn at \(executablePath)")
        guard let configData = Data(base64Encoded: server.openVpnConfigDataBase64) else {
            throw HelperOperationError(code: "invalidConfig", message: "server config was not valid base64")
        }

        let configText = String(decoding: configData, as: UTF8.self)
        allowedRemotes = OpenVPNConfigParser.parseRemotes(configText: configText)
        self.killSwitchEnabled = killSwitchEnabled
        tunnelInterfaceArmed = false
        tunnelInitialized = false
        isExplicitDisconnect = false

        if killSwitchEnabled {
            do {
                try killSwitch.engage(allowedRemotes: allowedRemotes)
                log("[killswitch] armed (LAN + \(allowedRemotes.count) remote(s)), tunnel interface pending")
            } catch {
                log("[killswitch] engage failed: \(error)")
                throw HelperOperationError(code: "killSwitchFailed", message: "failed to arm kill switch: \(error)")
            }
        }

        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("vpngate-\(UUID().uuidString).ovpn")
        try configData.write(to: configURL)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let port = try PortReservation.reserveLoopbackPort()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--verb", "4",
            "--config", configURL.path,
            "--data-ciphers", "AES-128-CBC",
            "--management", "127.0.0.1", String(port),
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data means EOF -- the dispatch source backing this
            // handler considers the FD perpetually "readable" at EOF, so
            // leaving the handler installed makes GCD re-invoke this
            // closure continuously as fast as possible, pegging CPU
            // forever instead of firing only when there's real output.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                self?.persistLogLine(String(line))
                self?.onLogLine?(LogLine(text: String(line), timestamp: Date()))
                self?.armTunnelInterfaceIfNeeded(fromLogLine: String(line))
                if String(line).localizedCaseInsensitiveContains("Initialization Sequence Completed") {
                    self?.tunnelInitialized = true
                }
            }
        }

        updateState(phase: .connecting, server: server)
        process.terminationHandler = { [weak self] _ in
            self?.handleUnexpectedExit()
        }
        try process.run()
        self.process = process

        do {
            log("[mgmt] dialing management port \(port)")
            let client = try await ManagementClient.connectWithRetry(host: "127.0.0.1", port: port) { [weak self] line in
                self?.log("[mgmt] \(line)")
            }
            log("[mgmt] connected, greeting read successfully")
            self.managementClient = client
            _ = try await client.waitForConnectedState(timeout: 60) { [weak self] line in
                self?.log("[mgmt] \(line)")
            } onUpdate: { [weak self] state in
                self?.updateState(phase: ConnectionPhase(rawValue: state.lowercased()) ?? .unknown, server: server)
            }
        } catch {
            log("[mgmt] connect flow threw: \(error)")
            // A failed control-channel dial after openvpn has already
            // reported the tunnel itself up is not a connection failure --
            // routes are installed and traffic is flowing. Tearing the
            // whole tunnel down here would trade a working (but
            // unmonitorable/unsignalable) VPN connection for no connection
            // at all, which is strictly worse for the user. Stay connected;
            // `disconnect()` already falls back to `process.terminate()`
            // when `managementClient` is nil, so the user can still stop it.
            guard !(error is CancellationError), tunnelInitialized else {
                // A user-cancelled attempt (Stop clicked mid-connect, or a
                // different server picked before this one resolved) is not
                // a connection failure -- the fail-closed "stay armed"
                // policy below is for genuine handshake failures, where
                // blocking until retry is the point. Leaving pf armed
                // after the user explicitly asked to stop would just
                // strand them.
                let isCancellation = error is CancellationError
                await cleanUpAfterFailedConnect(
                    disengageKillSwitch: isCancellation,
                    lastError: isCancellation ? nil : "connect failed: \(error)"
                )
                throw error
            }
            log("[mgmt] tunnel already up (Initialization Sequence Completed) -- staying connected without a live control channel")
            updateState(phase: .connected, server: server)
        }
    }

    /// Scans openvpn's own log output for its interface-open line (e.g.
    /// "Opened utun device utun3") to learn which utun interface the
    /// tunnel is using, then extends the kill switch's pf rules to allow
    /// traffic on it. Runs at most once per connection attempt. Not
    /// actor-isolated -- this fires from the readabilityHandler's
    /// background queue, same as the rest of this closure's log
    /// bookkeeping, which already tolerates concurrent access to this
    /// class's state (see the class-level docs on `process`/
    /// `managementClient`).
    private func armTunnelInterfaceIfNeeded(fromLogLine line: String) {
        guard killSwitchEnabled, !tunnelInterfaceArmed else { return }
        guard line.localizedCaseInsensitiveContains("open"),
              let range = line.range(of: "utun[0-9]+", options: .regularExpression) else { return }
        let interfaceName = String(line[range])
        tunnelInterfaceArmed = true
        do {
            try killSwitch.extendWithTunnelInterface(interfaceName, allowedRemotes: allowedRemotes)
            log("[killswitch] armed for tunnel interface \(interfaceName)")
        } catch {
            log("[killswitch] failed to extend for tunnel interface \(interfaceName): \(error)")
            Task { [weak self] in
                await self?.cleanUpAfterFailedConnect(disengageKillSwitch: true, lastError: "kill switch failed to arm for tunnel interface")
            }
        }
    }

    /// Tears down a connection attempt that didn't make it to CONNECTED.
    ///
    /// `disengageKillSwitch: true` fully clears pf and reports
    /// `.disconnected` -- used when there's nothing left to protect (e.g.
    /// arming the tunnel-interface exception itself failed, so the
    /// tunnel's own traffic was never going to be let through anyway).
    ///
    /// `disengageKillSwitch: false` leaves pf armed at whatever exception
    /// set it already had (LAN + server, since the interface exception is
    /// only added after CONNECTED-adjacent progress) and reports
    /// `.blocked` instead of `.disconnected` -- used when the management
    /// handshake itself failed, since blocking non-LAN traffic until the
    /// user retries is the fail-closed behavior the kill switch exists
    /// for.
    private func cleanUpAfterFailedConnect(disengageKillSwitch: Bool, lastError: String? = nil) async {
        isExplicitDisconnect = true
        if let managementClient {
            try? await managementClient.disconnect()
            await managementClient.close()
        }
        managementClient = nil
        process?.terminate()
        process = nil
        if disengageKillSwitch, killSwitchEnabled {
            killSwitch.disengage()
            log("[killswitch] disengaged after failed connect")
            killSwitchEnabled = false
        } else if killSwitchEnabled {
            let exceptions = tunnelInterfaceArmed ? "LAN + server + tunnel interface" : "LAN + server only"
            log("[killswitch] left armed (\(exceptions)) after failed connect -- pf still blocking non-tunnel traffic")
        }
        tunnelInterfaceArmed = false
        updateState(phase: killSwitchEnabled ? .blocked : .disconnected, server: nil, lastError: lastError)
    }

    func disconnect() async throws {
        // Unlike the early-return this replaced, this always tears down
        // `process` even if `managementClient` is nil -- e.g. openvpn is
        // running but hasn't finished the management handshake yet -- so a
        // disconnect/stop request never leaves it dangling.
        isExplicitDisconnect = true
        if let managementClient {
            try await managementClient.disconnect()
            await managementClient.close()
        }
        managementClient = nil
        process?.terminate()
        process = nil
        if killSwitchEnabled {
            killSwitch.disengage()
            log("[killswitch] disengaged")
        }
        killSwitchEnabled = false
        tunnelInterfaceArmed = false
        updateState(phase: .disconnected, server: nil)
    }

    /// Runs whenever openvpn exits on its own, whether that's an
    /// unexpected crash/kill or the tail end of an explicit
    /// `disconnect()` -- `isExplicitDisconnect` (set at the top of
    /// `disconnect()`/`cleanUpAfterFailedConnect()`) distinguishes the
    /// two so this doesn't clobber state a normal disconnect already
    /// finished setting. An unexpected exit while the kill switch is
    /// armed means pf is still blocking non-tunnel traffic -- that's the
    /// whole point -- but the app needs to know the tunnel itself is gone
    /// rather than keep showing a stale "Connected".
    private func handleUnexpectedExit() {
        guard !isExplicitDisconnect else { return }
        process = nil
        managementClient = nil
        if killSwitchEnabled {
            log("[killswitch] openvpn exited unexpectedly -- kill switch still blocking non-tunnel traffic")
        } else {
            log("openvpn exited unexpectedly")
        }
        updateState(phase: killSwitchEnabled ? .blocked : .disconnected, server: nil, lastError: "openvpn exited unexpectedly")
    }

    private func updateState(phase: ConnectionPhase, server: Server?, lastError: String? = nil) {
        currentState = ConnectionState(
            phase: phase,
            hostName: server?.hostName ?? "",
            ipAddr: server?.ipAddr ?? "",
            countryLong: server?.countryLong ?? "",
            countryShort: server?.countryShort ?? "",
            startedAt: phase == .connected ? Date() : currentState.startedAt,
            lastError: lastError
        )
        onStateChange?(currentState)
    }
}
