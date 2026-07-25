import XCTest
@testable import VpngateShared

final class ServerListCacheTests: XCTestCase {
    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("servers.json")
    }

    private let sampleServers = [
        Server(hostName: "a.example.com", countryLong: "Japan", countryShort: "JP", score: 1, ipAddr: "1.1.1.1", openVpnConfigDataBase64: "YQ==", ping: "10")
    ]

    func testSaveThenLoadRoundTrips() throws {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try ServerListCache.save(sampleServers, to: url)
        let loaded = ServerListCache.load(from: url)
        XCTAssertEqual(loaded, sampleServers)
    }

    func testLoadMissingFileReturnsNil() {
        let url = tempCacheURL()
        XCTAssertNil(ServerListCache.load(from: url))
    }

    func testIsExpiredForMissingFile() {
        let url = tempCacheURL()
        XCTAssertTrue(ServerListCache.isExpired(url: url))
    }

    func testIsExpiredRespectsTTL() throws {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ServerListCache.save(sampleServers, to: url)

        XCTAssertFalse(ServerListCache.isExpired(url: url, ttl: 86400, now: Date()))
        XCTAssertTrue(ServerListCache.isExpired(url: url, ttl: 1, now: Date().addingTimeInterval(3600)))
    }
}
