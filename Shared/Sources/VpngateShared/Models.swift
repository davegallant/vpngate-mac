import Foundation

public struct Server: Codable, Equatable {
    public var hostName: String
    public var countryLong: String
    public var countryShort: String
    public var score: Int
    public var ipAddr: String
    public var openVpnConfigDataBase64: String
    public var ping: String

    public init(hostName: String, countryLong: String, countryShort: String, score: Int, ipAddr: String, openVpnConfigDataBase64: String, ping: String) {
        self.hostName = hostName
        self.countryLong = countryLong
        self.countryShort = countryShort
        self.score = score
        self.ipAddr = ipAddr
        self.openVpnConfigDataBase64 = openVpnConfigDataBase64
        self.ping = ping
    }
}

public enum ConnectionPhase: String, Codable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case exiting
    case failed
    /// The kill switch is still blocking non-tunnel traffic, but `openvpn`
    /// exited without an explicit `disconnect()` -- distinct from
    /// `.disconnected` so the app never shows a stale "Connected" (or a
    /// misleadingly plain "Not connected") after an unexpected drop.
    case blocked
    case unknown
}

public struct ConnectionState: Codable, Equatable {
    public var phase: ConnectionPhase
    public var hostName: String
    public var ipAddr: String
    public var countryLong: String
    public var countryShort: String
    public var startedAt: Date?
    public var lastError: String?

    public init(phase: ConnectionPhase, hostName: String, ipAddr: String, countryLong: String, countryShort: String = "", startedAt: Date?, lastError: String?) {
        self.phase = phase
        self.hostName = hostName
        self.ipAddr = ipAddr
        self.countryLong = countryLong
        self.countryShort = countryShort
        self.startedAt = startedAt
        self.lastError = lastError
    }

    public static let disconnected = ConnectionState(phase: .disconnected, hostName: "", ipAddr: "", countryLong: "", countryShort: "", startedAt: nil, lastError: nil)
}

public struct LogLine: Codable, Equatable {
    public var text: String
    public var timestamp: Date

    public init(text: String, timestamp: Date) {
        self.text = text
        self.timestamp = timestamp
    }
}

public struct HelperOperationError: Codable, Equatable, Error {
    public var code: String
    public var message: String
    public var logTail: [String]

    public init(code: String, message: String, logTail: [String] = []) {
        self.code = code
        self.message = message
        self.logTail = logTail
    }

    public static func openvpnNotFound() -> HelperOperationError {
        HelperOperationError(
            code: "openvpnNotFound",
            message: "openvpn not found — the bundled binary is missing or unreadable; try reinstalling VPNGate.app"
        )
    }
}
