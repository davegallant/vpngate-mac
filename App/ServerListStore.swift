import Combine
import Foundation
import VpngateShared

@MainActor
final class ServerListStore: ObservableObject {
    @Published var servers: [Server] = []
    @Published var errorMessage: String?
    @Published private(set) var isRefreshing = false

    private let listURL = URL(string: "https://www.vpngate.net/api/iphone/")!
    private let cacheURL: URL

    init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vpngate", isDirectory: true)
        let cacheURL = cacheDir.appendingPathComponent("servers.json")
        self.cacheURL = cacheURL
        // Started here (not from a View's .task) so the fetch survives the
        // menu bar dropdown opening/closing -- SwiftUI cancels .task work
        // when its view disappears, which was cancelling this fetch every
        // time the user closed the menu before it finished.
        //
        // Cache load runs off the main thread: decoding the full server
        // list (base64 OpenVPN configs for every entry) synchronously here
        // used to stall app launch until it finished.
        Task {
            if let cached = await Task.detached(priority: .utility, operation: { ServerListCache.load(from: cacheURL) }).value {
                servers = cached
            }
            await refreshIfNeeded()
        }
    }

    /// Fetches a fresh list if the 24h cache has expired; on failure, keeps
    /// whatever's already loaded (from cache or a previous fetch) and sets
    /// errorMessage instead of clearing servers.
    func refreshIfNeeded() async {
        guard ServerListCache.isExpired(url: cacheURL) else { return }
        await refresh()
    }

    /// Always fetches a fresh list, bypassing the 24h cache -- used by the
    /// manual "Refresh" button. `refreshIfNeeded()` above is the automatic,
    /// cache-aware path and just delegates here once it decides a fetch is
    /// actually needed.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: listURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "Failed to fetch server list"
                return
            }
            let decoded = try ServerListDecoder.decode(csv: data)
            servers = decoded
            errorMessage = nil
            try? ServerListCache.save(decoded, to: cacheURL)
        } catch {
            errorMessage = "Failed to fetch server list: \(error.localizedDescription)"
        }
    }
}
