import Foundation

/// Disk cache for the decoded server list, matching pkg/vpn/cache.go's
/// 24-hour TTL (checked against the cache file's modification time).
public enum ServerListCache {
    public static func load(from url: URL) -> [Server]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Server].self, from: data)
    }

    public static func save(_ servers: [Server], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(servers)
        try data.write(to: url, options: .atomic)
    }

    public static func isExpired(url: URL, ttl: TimeInterval = 86400, now: Date = Date()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return true
        }
        return now.timeIntervalSince(modified) > ttl
    }
}
