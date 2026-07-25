import SwiftUI
import VpngateShared

/// Flag emojis are Unicode Regional Indicator Symbol pairs -- 'A'..'Z' map
/// to U+1F1E6..U+1F1FF, so a 2-letter ISO country code converts directly
/// without needing a hardcoded code->emoji table.
private func countryFlagEmoji(countryShort: String) -> String {
    let code = countryShort.uppercased()
    let regionalIndicatorBase: UInt32 = 127397 // U+1F1E6 - "A"
    guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "🏳️" }
    let scalars = code.unicodeScalars.compactMap { Unicode.Scalar(regionalIndicatorBase + $0.value) }
    guard scalars.count == 2 else { return "🏳️" }
    return String(String.UnicodeScalarView(scalars))
}

private extension Server {
    var flagEmoji: String { countryFlagEmoji(countryShort: countryShort) }

    /// VPNGate's `CountryLong` values are ISO-style official names ("Korea
    /// Republic of", "Taiwan Province of China") that read awkwardly in a
    /// short list. Deriving the display name from the ISO code via `Locale`
    /// gives a clean name for every country without a hardcoded lookup
    /// table, falling back to the raw value for any code it doesn't
    /// recognize.
    var displayCountryName: String {
        Locale.current.localizedString(forRegionCode: countryShort.uppercased()) ?? countryLong
    }
}

struct MenuBarView: View {
    @EnvironmentObject var helper: HelperClient
    @EnvironmentObject var serverList: ServerListStore
    @Environment(\.openWindow) private var openWindow
    @State private var countryFilter: String = ""
    @State private var isConnecting = false
    @State private var isStopping = false
    @State private var errorMessage: String?
    /// Backs the List's native row selection -- reset to nil right after
    /// each click so a click reads as "connect to this" rather than leaving
    /// a row permanently marked selected; the green background is what
    /// persistently indicates the active server instead.
    @State private var selectedHostName: String?
    /// Which server a still-in-flight connect() targets, so that row can
    /// stay highlighted through the whole CONNECTING/AUTH/GET_CONFIG
    /// sequence instead of only lighting up once phase == .connected.
    @State private var connectingHostName: String?

    private var displayedErrors: [String] {
        [helper.registrationError, serverList.errorMessage, errorMessage].compactMap { $0 }
    }

    private var filteredServers: [Server] {
        guard !countryFilter.isEmpty else { return serverList.servers }
        return serverList.servers.filter {
            $0.countryLong.localizedCaseInsensitiveContains(countryFilter)
        }
    }

    private func isConnected(_ server: Server) -> Bool {
        helper.connectionState.phase == .connected && server.hostName == helper.connectionState.hostName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine

            HStack {
                TextField("Filter by country", text: $countryFilter)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await serverList.refresh() }
                } label: {
                    if serverList.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(serverList.isRefreshing)
                .help("Refresh server list")
            }

            ForEach(displayedErrors, id: \.self) { message in
                Text(message).foregroundColor(.red).font(.caption)
            }

            List(filteredServers, id: \.hostName, selection: $selectedHostName) { server in
                let isConnectedServer = isConnected(server)
                let isConnectingServer = isConnecting && server.hostName == connectingHostName
                HStack(spacing: 6) {
                    Text(server.flagEmoji)
                        .frame(width: 20, alignment: .center)
                    Text(server.ipAddr)
                        .lineLimit(1)
                    if isConnectingServer {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 8)
                    Text(server.displayCountryName)
                        .font(.caption)
                        .foregroundColor(isConnectedServer ? .black.opacity(0.7) : .secondary)
                        .lineLimit(1)
                }
                .foregroundColor(isConnectedServer ? .black : nil)
                .listRowBackground(
                    isConnectedServer ? Color.green
                    : isConnectingServer ? Color.green.opacity(0.25)
                    : nil
                )
            }
            .listStyle(.plain)
            .disabled(isConnecting)
            .onChange(of: selectedHostName) { _, newValue in
                defer { selectedHostName = nil }
                guard let newValue, let server = filteredServers.first(where: { $0.hostName == newValue }), !isConnected(server) else { return }
                connect(to: server)
            }
            .frame(minHeight: 200)

            Divider()

            HStack {
                Button("Open Logs") {
                    // openWindow(id:) only creates the window if it doesn't
                    // exist yet -- if it's already open (just not frontmost),
                    // this call is a no-op, so the window needs to be found
                    // and brought forward explicitly every time.
                    openWindow(id: "logs")
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.title == "Vpngate Logs" }?.makeKeyAndOrderFront(nil)
                }

                Spacer()

                if helper.connectionState.phase != .disconnected {
                    // Any non-disconnected phase means there's something to
                    // stop -- OpenVPN's real intermediate states (RECONNECTING,
                    // WAIT, AUTH, TCP_CONNECT, etc.) map to ConnectionPhase
                    // values other than just .connecting, so checking only
                    // .connected/.connecting here hid the button for most of an
                    // actual connection attempt, including a server stuck
                    // looping RECONNECTING forever.
                    if isStopping {
                        ProgressView().controlSize(.small)
                    }
                    Button(helper.connectionState.phase == .connected ? "Disconnect" : "Stop", action: disconnect)
                        .foregroundColor(.red)
                        .disabled(isStopping)
                }
            }
        }
        .padding()
        .frame(width: 320)
        .task {
            helper.registerHelperIfNeeded()
            await serverList.refreshIfNeeded()
            await helper.refreshStatus()
        }
    }

    private var statusLine: some View {
        HStack {
            if isConnecting || isStopping {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(helper.connectionState.phase == .connected ? .green : .gray)
                    .frame(width: 8, height: 8)
            }
            Text(statusText)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
    }

    private var statusText: String {
        switch helper.connectionState.phase {
        case .connected:
            let flag = countryFlagEmoji(countryShort: helper.connectionState.countryShort)
            return "Connected — \(helper.connectionState.ipAddr) \(flag)"
        case .connecting:
            return "Connecting…"
        case .disconnected:
            return "Not connected"
        default:
            return helper.connectionState.phase.rawValue.capitalized
        }
    }

    private func connect(to server: Server) {
        isConnecting = true
        connectingHostName = server.hostName
        errorMessage = nil
        Task {
            do {
                try await helper.connect(to: server)
            } catch let err as HelperOperationError where err.code == "cancelled" {
                // User hit Stop while this was connecting -- not a real error.
            } catch let err as HelperOperationError {
                errorMessage = err.message
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
            connectingHostName = nil
        }
    }

    private func disconnect() {
        isStopping = true
        errorMessage = nil
        Task {
            do {
                try await helper.disconnect()
            } catch let err as HelperOperationError {
                errorMessage = err.message
            } catch {
                errorMessage = error.localizedDescription
            }
            isStopping = false
        }
    }
}
