import Combine
import Foundation
import ServiceManagement
import VpngateShared

@MainActor
final class HelperClient: NSObject, ObservableObject, VpngateHelperClientXPCProtocol {
    /// Lets `AppDelegate` reach the live instance to finish an in-flight
    /// disconnect before the app terminates -- `AppDelegate` is created by
    /// `@NSApplicationDelegateAdaptor` independently of this SwiftUI
    /// `@StateObject`, so there's no view-hierarchy path to hand it a
    /// reference directly.
    static weak var shared: HelperClient?

    @Published var connectionState: ConnectionState = .disconnected
    @Published var helperAvailable = false
    @Published var registrationError: String?

    private var connection: NSXPCConnection?
    private var logContinuation: AsyncStream<LogLine>.Continuation?
    /// Guards `reportDecodeFailure` so a persistently mismatched schema (the
    /// helper never got kickstarted onto the new build) logs once instead of
    /// spamming once per XPC message -- didReceiveLogLine alone can fire
    /// many times a second.
    private var hasReportedDecodeFailure = false
    let logLines: AsyncStream<LogLine>

    override init() {
        var continuation: AsyncStream<LogLine>.Continuation!
        self.logLines = AsyncStream { continuation = $0 }
        super.init()
        self.logContinuation = continuation
        HelperClient.shared = self
    }

    /// Guards the SMAppService round trip below to run at most once per
    /// launch -- `registerHelperIfNeeded()` is called from MenuBarView's
    /// `.task`, which re-fires on every menu bar dropdown open, and
    /// `SMAppService.status` is a synchronous XPC call that made every
    /// single open stall on the main thread once this was left unguarded.
    private var hasAttemptedRegistration = false

    /// Registers the embedded helper daemon via SMAppService. Triggers a
    /// one-time approval prompt (System Settings > Login Items) the first
    /// time it's called; subsequent launches are silent once approved.
    func registerHelperIfNeeded() {
        guard !hasAttemptedRegistration else {
            connectToHelperIfNeeded()
            return
        }
        let service = SMAppService.daemon(plistName: "com.davegallant.vpngate.helper.plist")
        switch service.status {
        case .enabled:
            hasAttemptedRegistration = true
            registrationError = nil
            connectToHelperIfNeeded()
        case .notRegistered, .notFound:
            do {
                try service.register()
                hasAttemptedRegistration = true
                registrationError = nil
                connectToHelperIfNeeded()
            } catch {
                registrationError = "Failed to register helper: \(error.localizedDescription)"
            }
        case .requiresApproval:
            // Left unguarded: the user may approve it in System Settings
            // between one menu open and the next, so this needs to keep
            // re-checking until it resolves to .enabled.
            registrationError = "Approve Vpngate under System Settings → General → Login Items & Extensions"
            SMAppService.openSystemSettingsLoginItems()
        @unknown default:
            hasAttemptedRegistration = true
            connectToHelperIfNeeded()
        }
    }

    /// This is called on every menu bar dropdown open (via MenuBarView's
    /// `.task`, which re-runs each time the view reappears), so it must not
    /// unconditionally tear down and recreate an already-live connection --
    /// doing so used to silently drop the in-flight/established connection
    /// state on every single click of the menu bar icon.
    private func connectToHelperIfNeeded() {
        guard connection == nil else {
            helperAvailable = true
            return
        }
        let connection = NSXPCConnection(machServiceName: VpngateIdentifiers.helperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: VpngateHelperXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: VpngateHelperClientXPCProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.helperAvailable = false
                self?.connection = nil
            }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.helperAvailable = false
                self?.connection = nil
            }
        }
        connection.resume()
        self.connection = connection
        helperAvailable = true
    }

    private func remoteHelper() -> VpngateHelperXPCProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.helperAvailable = false }
        } as? VpngateHelperXPCProtocol
    }

    func connect(to server: Server, killSwitchEnabled: Bool) async throws {
        guard let helper = remoteHelper() else {
            throw HelperOperationError(code: "helperUnavailable", message: "Helper unavailable")
        }
        let payload = try JSONEncoder().encode(server)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            helper.connect(serverJSON: payload, killSwitchEnabled: killSwitchEnabled) { errorData in
                if let errorData, let err = try? JSONDecoder().decode(HelperOperationError.self, from: errorData) {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func disconnect() async throws {
        guard let helper = remoteHelper() else {
            throw HelperOperationError(code: "helperUnavailable", message: "Helper unavailable")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            helper.disconnect { errorData in
                if let errorData, let err = try? JSONDecoder().decode(HelperOperationError.self, from: errorData) {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func refreshStatus() async {
        guard let helper = remoteHelper() else { return }
        let data: Data = await withCheckedContinuation { continuation in
            helper.status { data in continuation.resume(returning: data) }
        }
        if let state = try? JSONDecoder().decode(ConnectionState.self, from: data) {
            connectionState = state
        }
    }

    /// Fetches the helper's recent-log backlog (oldest first) — used to
    /// pre-populate the log viewer before it starts consuming `logLines`
    /// for new lines going forward.
    func fetchRecentLogs(tailLines: Int) async -> [LogLine] {
        guard let helper = remoteHelper() else { return [] }
        let payloads: [Data] = await withCheckedContinuation { continuation in
            helper.fetchRecentLogs(tailLines: tailLines) { data in continuation.resume(returning: data) }
        }
        return payloads.compactMap { try? JSONDecoder().decode(LogLine.self, from: $0) }
    }

    // MARK: - VpngateHelperClientXPCProtocol (called by the helper)

    nonisolated func connectionStateDidChange(stateJSON: Data) {
        do {
            let state = try JSONDecoder().decode(ConnectionState.self, from: stateJSON)
            Task { @MainActor in self.connectionState = state }
        } catch {
            // A decode failure here almost always means the helper daemon is
            // running an older build than the app (it's a persistent
            // LaunchDaemon that Xcode doesn't restart on rebuild) -- without
            // this, that mismatch silently drops every state update with no
            // visible symptom beyond "the UI never updates."
            Task { @MainActor in self.reportDecodeFailure(context: "connectionStateDidChange", error: error) }
        }
    }

    nonisolated func didReceiveLogLine(lineJSON: Data) {
        do {
            let line = try JSONDecoder().decode(LogLine.self, from: lineJSON)
            Task { @MainActor in self.logContinuation?.yield(line) }
        } catch {
            Task { @MainActor in self.reportDecodeFailure(context: "didReceiveLogLine", error: error) }
        }
    }

    private func reportDecodeFailure(context: String, error: Error) {
        guard !hasReportedDecodeFailure else { return }
        hasReportedDecodeFailure = true
        let text = "[app] failed to decode \(context) from helper: \(error) -- the helper daemon is likely running an older build; run `sudo launchctl kickstart -k system/com.davegallant.vpngate.helper` and try again"
        logContinuation?.yield(LogLine(text: text, timestamp: Date()))
    }
}
