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
    private(set) var currentState = ConnectionState.disconnected

    var onStateChange: ((ConnectionState) -> Void)?
    var onLogLine: ((LogLine) -> Void)?

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

    func connect(to server: Server) async throws {
        guard let executablePath = resolveOpenvpnPath() else {
            throw HelperOperationError.openvpnNotFound()
        }
        log("using openvpn at \(executablePath)")
        guard let configData = Data(base64Encoded: server.openVpnConfigDataBase64) else {
            throw HelperOperationError(code: "invalidConfig", message: "server config was not valid base64")
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
            }
        }

        updateState(phase: .connecting, server: server)
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
            // A failed connect() must never leave the openvpn process
            // dangling with no way to reach it -- disconnect() only works
            // once self.process/self.managementClient are set, which a
            // thrown error here would otherwise leave running but orphaned.
            await cleanUpAfterFailedConnect()
            throw error
        }
    }

    private func cleanUpAfterFailedConnect() async {
        if let managementClient {
            try? await managementClient.disconnect()
            await managementClient.close()
        }
        managementClient = nil
        process?.terminate()
        process = nil
        updateState(phase: .disconnected, server: nil)
    }

    func disconnect() async throws {
        // Unlike the early-return this replaced, this always tears down
        // `process` even if `managementClient` is nil -- e.g. openvpn is
        // running but hasn't finished the management handshake yet -- so a
        // disconnect/stop request never leaves it dangling.
        if let managementClient {
            try await managementClient.disconnect()
            await managementClient.close()
        }
        managementClient = nil
        process?.terminate()
        process = nil
        updateState(phase: .disconnected, server: nil)
    }

    private func updateState(phase: ConnectionPhase, server: Server?) {
        currentState = ConnectionState(
            phase: phase,
            hostName: server?.hostName ?? "",
            ipAddr: server?.ipAddr ?? "",
            countryLong: server?.countryLong ?? "",
            countryShort: server?.countryShort ?? "",
            startedAt: phase == .connected ? Date() : currentState.startedAt,
            lastError: nil
        )
        onStateChange?(currentState)
    }
}
