import Foundation

/// XPC interface the app calls on the privileged helper. All payloads
/// cross the XPC boundary as JSON-encoded Data (rather than NSSecureCoding
/// model classes) so VpngateShared's models can stay plain Codable structs.
/// A nil `Data?` reply on connect/disconnect means success; non-nil means
/// a JSON-encoded HelperOperationError.
@objc public protocol VpngateHelperXPCProtocol {
    /// `serverJSON` is a JSON-encoded Server.
    func connect(serverJSON: Data, reply: @escaping (Data?) -> Void)
    func disconnect(reply: @escaping (Data?) -> Void)
    /// `reply` receives a JSON-encoded ConnectionState.
    func status(reply: @escaping (Data) -> Void)
    /// `reply` receives up to `tailLines` JSON-encoded LogLine entries,
    /// oldest first.
    func fetchRecentLogs(tailLines: Int, reply: @escaping ([Data]) -> Void)
}

/// XPC interface the helper calls back on the app (the app registers an
/// object conforming to this as its connection's exportedObject).
@objc public protocol VpngateHelperClientXPCProtocol {
    /// `stateJSON` is a JSON-encoded ConnectionState.
    func connectionStateDidChange(stateJSON: Data)
    /// `lineJSON` is a JSON-encoded LogLine.
    func didReceiveLogLine(lineJSON: Data)
}

/// Shared identifiers so the app, helper, Info.plist, and launchd plist
/// can't drift independently.
public enum VpngateIdentifiers {
    public static let appBundleID = "com.davegallant.vpngate"
    public static let helperMachServiceName = "com.davegallant.vpngate.helper"
}
