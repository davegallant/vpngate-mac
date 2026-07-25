import Foundation
import Network

public enum ManagementError: Error, Equatable, LocalizedError {
    case connectionFailed(String)
    case noStateFound
    case unexpectedClose

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "Management connection failed: \(message)"
        case .noStateFound:
            return "No connection state reported by OpenVPN"
        case .unexpectedClose:
            return "Management connection closed unexpectedly"
        }
    }
}

/// Ensures a completion/continuation callback that a system API might
/// invoke more than once (or from multiple threads) only actually resumes
/// once. Internal (not `public`) but visible to VpngateSharedTests via
/// `@testable import`, so test code that wraps NWListener/NWConnection
/// callbacks the same way can reuse it instead of duplicating the lock.
final class ResumeOnceGuard: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    /// Returns true the first time it's called; false on every call after.
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

/// A client for OpenVPN's plaintext management protocol. Mirrors
/// pkg/daemon/management.go in the Go CLI for the basics: discards the
/// greeting line on connect, `state()` sends "state\n" and reads lines
/// until "END", parsing the second comma-separated field of the first
/// non-empty line as the connection state; `disconnect()` sends
/// "signal SIGTERM\n". `waitForConnectedState(timeout:onDebugLine:onUpdate:)` is a
/// deliberate addition beyond the Go CLI: querying `state()` repeatedly
/// while a connection is being established proved unreliable in testing
/// (OpenVPN's line-oriented protocol didn't consistently answer fresh
/// one-shot queries mid-handshake), so it drives progress off real-time
/// `>STATE:` push notifications instead.
public actor ManagementClient {
    private let connection: NWConnection
    private var buffer = Data()

    /// Callers waiting for more bytes to arrive (registered by
    /// `waitForMoreData()`), keyed so a cancelled/timed-out caller's
    /// continuation can be resumed and removed individually without
    /// disturbing any other outstanding waiter.
    private var dataWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Set once the connection has failed or closed; new/queued waiters are
    /// resumed with this immediately instead of waiting for bytes that will
    /// never come.
    private var terminalError: Error?
    private var receiveLoopStarted = false

    private init(connection: NWConnection) {
        self.connection = connection
    }

    public static func connect(
        host: String,
        port: UInt16,
        timeout: TimeInterval = 5,
        onDebugLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ManagementClient {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ManagementError.connectionFailed("invalid port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let client = ManagementClient(connection: connection)
        try await client.waitUntilReady(timeout: timeout, onDebugLine: onDebugLine)
        // Started once the connection is ready (not lazily on first read) so
        // it keeps draining the socket into `buffer` for the rest of the
        // connection's life, independent of any single readLine() call's
        // timeout or cancellation -- see waitForMoreData()'s doc comment for
        // why that separation matters.
        await client.startReceiveLoopIfNeeded()
        _ = try await client.readLine(timeout: timeout) // discard greeting
        return client
    }

    /// Repeatedly attempts `connect(host:port:)` with a short per-attempt
    /// timeout, retrying on failure, until `overallTimeout` elapses. Needed
    /// because the caller starts the openvpn process and immediately dials
    /// its management port -- if the dial lands before openvpn has actually
    /// bound the listening socket, TCP refuses the connection, which
    /// NWConnection reports as `.waiting` (not `.failed`) with no automatic
    /// recovery for a fixed loopback address. A single long-timeout attempt
    /// just sits in that `.waiting` state until the whole timeout elapses;
    /// retrying with a fresh connection is what actually recovers from
    /// losing this one-time startup race.
    public static func connectWithRetry(
        host: String,
        port: UInt16,
        perAttemptTimeout: TimeInterval = 1.5,
        retryInterval: TimeInterval = 0.3,
        overallTimeout: TimeInterval = 15,
        onDebugLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ManagementClient {
        let deadline = Date().addingTimeInterval(overallTimeout)
        var lastError: Error = ManagementError.connectionFailed("connectWithRetry made no attempts")
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            onDebugLine?("connect attempt \(attempt)")
            do {
                return try await connect(host: host, port: port, timeout: perAttemptTimeout, onDebugLine: onDebugLine)
            } catch {
                lastError = error
                onDebugLine?("connect attempt \(attempt) failed: \(error)")
                try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
            }
        }
        onDebugLine?("connectWithRetry exhausted overall timeout")
        throw lastError
    }

    /// Races `operation` against a `timeout`-second sleep; whichever
    /// finishes first wins, and the loser is cancelled. Needed because
    /// NWConnection's state machine can sit in a non-terminal state (e.g.
    /// `.waiting`, retrying indefinitely) for a refused/unreachable
    /// connection instead of promptly reporting `.failed` — without this,
    /// a bad host/port (or a peer that stops sending mid-response) can
    /// hang forever regardless of the `timeout` parameter callers pass.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        onTimeout: @Sendable @escaping () -> Void = {},
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                onTimeout()
                throw ManagementError.connectionFailed("timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func waitUntilReady(timeout: TimeInterval, onDebugLine: (@Sendable (String) -> Void)? = nil) async throws {
        try await Self.withTimeout(timeout, onTimeout: { [connection] in connection.cancel() }) { [connection] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let guardOnce = ResumeOnceGuard()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard guardOnce.tryResume() else { return }
                        continuation.resume()
                    case .waiting(let error):
                        // Not terminal -- NWConnection can sit here
                        // indefinitely (e.g. connection-refused while
                        // openvpn hasn't bound its management port yet)
                        // with no automatic recovery for a fixed loopback
                        // address, so this alone never resumes the
                        // continuation. Logged so a stuck dial is visible
                        // instead of silently swallowed by `default: break`.
                        onDebugLine?("NWConnection .waiting: \(error)")
                    case .failed(let error):
                        guard guardOnce.tryResume() else { return }
                        continuation.resume(throwing: ManagementError.connectionFailed(error.localizedDescription))
                    case .cancelled:
                        guard guardOnce.tryResume() else { return }
                        continuation.resume(throwing: ManagementError.connectionFailed("cancelled"))
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .utility))
            }
        }
    }

    /// Starts (once) a self-perpetuating `connection.receive` loop that
    /// drains every byte the peer sends into `buffer`, regardless of
    /// whether anything is currently waiting for a line. Kept separate from
    /// `waitForMoreData()`'s per-call waiting so that a per-read timeout or
    /// an outer Task's cancellation only ever abandons a *waiter*, never
    /// the underlying socket read -- see `waitForMoreData()`.
    private func startReceiveLoopIfNeeded() {
        guard !receiveLoopStarted else { return }
        receiveLoopStarted = true
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            fail(ManagementError.connectionFailed(error.localizedDescription))
            return
        }
        if let data, !data.isEmpty {
            buffer.append(data)
            wakeAllWaiters()
        }
        if isComplete {
            fail(ManagementError.unexpectedClose)
            return
        }
        receiveNext()
    }

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let waiters = dataWaiters
        dataWaiters.removeAll()
        for (_, continuation) in waiters { continuation.resume(throwing: error) }
    }

    private func wakeAllWaiters() {
        let waiters = dataWaiters
        dataWaiters.removeAll()
        for (_, continuation) in waiters { continuation.resume() }
    }

    /// Suspends until `buffer` has grown (or the connection has failed/
    /// closed), without touching the underlying `connection.receive` call
    /// in flight from `startReceiveLoopIfNeeded()`'s loop. Unlike awaiting
    /// a raw `connection.receive` continuation directly, this *is*
    /// cancellable: `withTaskCancellationHandler` resumes this call's own
    /// waiter the moment its Task is cancelled (by an outer caller, or by
    /// `withTimeout`'s `group.cancelAll()` on a per-read timeout) without
    /// waiting for the socket to produce more bytes. That's what makes a
    /// per-read timeout in `readLine`/`waitForConnectedState` actually
    /// return instead of hanging forever -- previously this call awaited
    /// `connection.receive`'s continuation directly, which only resumes
    /// when the OS delivers more data, so cancelling it had no effect and
    /// `withThrowingTaskGroup` (which must await every child before
    /// returning) hung waiting for a read that would never arrive.
    private func waitForMoreData() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    dataWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = dataWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func readLineUnbounded() async throws -> String {
        while true {
            if let range = buffer.firstRange(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
            try await waitForMoreData()
        }
    }

    private func readLine(timeout: TimeInterval) async throws -> String {
        try await Self.withTimeout(timeout) { [self] in
            try await self.readLineUnbounded()
        }
    }

    private func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ManagementError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func state(timeout: TimeInterval = 5) async throws -> String {
        try await send("state\n")
        var lines: [String] = []
        while true {
            let line = try await readLine(timeout: timeout)
            if line == "END" { break }
            lines.append(line)
        }
        return try Self.parseState(lines)
    }

    /// Extracts the state field from OpenVPN's "state" command response.
    /// Each response line is comma-separated; the second field (index 1)
    /// is the connection state, per OpenVPN's management-notes.txt.
    static func parseState(_ lines: [String]) throws -> String {
        for line in lines {
            let fields = line.components(separatedBy: ",")
            if fields.count >= 2, !fields[1].isEmpty {
                return fields[1]
            }
        }
        throw ManagementError.noStateFound
    }

    /// Enables real-time state-change notifications (`state on`) and waits
    /// for a pushed `>STATE:...` line reporting CONNECTED, calling `onUpdate`
    /// with each intermediate state observed along the way. Used instead of
    /// repeatedly issuing one-shot `state` queries: OpenVPN's line-oriented
    /// management protocol doesn't reliably answer fresh command/response
    /// round-trips while a connection is actively being established, which
    /// in testing caused polling to time out even after OpenVPN had already
    /// logged "Initialization Sequence Completed". Real-time push
    /// notification is how OpenVPN's own GUI clients track progress.
    public func waitForConnectedState(
        timeout: TimeInterval,
        perReadTimeout: TimeInterval = 5,
        onDebugLine: (@Sendable (String) -> Void)? = nil,
        onUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        onDebugLine?("sending 'state on'")
        try await send("state on\n")
        onDebugLine?("'state on' sent, entering read loop")
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            // Without this check, cancelling the caller's Task (e.g. a user
            // hitting "Stop" while connecting) has no effect here: this loop
            // only reacts to the 60s `deadline` below, and the per-read
            // timeout races a Task.sleep that throws immediately on
            // cancellation -- but that gets swallowed by the `catch { ...;
            // continue }` below, so cancellation alone would otherwise just
            // be silently ignored and looping would continue regardless.
            guard !Task.isCancelled else {
                onDebugLine?("cancelled, giving up")
                throw CancellationError()
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                onDebugLine?("deadline exceeded, giving up")
                throw ManagementError.connectionFailed("timed out waiting for CONNECTED state")
            }
            let line: String
            do {
                line = try await readLine(timeout: min(remaining, perReadTimeout))
            } catch is CancellationError {
                onDebugLine?("readLine error (continuing): CancellationError()")
                continue // let the Task.isCancelled check above handle it next iteration
            } catch ManagementError.connectionFailed("timed out") {
                continue // nothing arrived in this window; keep waiting until deadline
            } catch {
                // Any other error means the underlying connection itself
                // failed (e.g. the peer reset it, or openvpn exited) --
                // unlike a plain read timeout, every subsequent read on a
                // dead connection fails instantly too, so retrying here
                // just spins as fast as the CPU allows, spamming this same
                // error thousands of times before the deadline instead of
                // failing fast.
                onDebugLine?("readLine error, giving up: \(error)")
                throw error
            }
            onDebugLine?("raw line: \(line)")
            guard line.hasPrefix(">STATE:") else { continue } // e.g. the "state on" SUCCESS confirmation
            let payload = String(line.dropFirst(">STATE:".count))
            let fields = payload.components(separatedBy: ",")
            guard fields.count >= 2, !fields[1].isEmpty else { continue }
            onUpdate?(fields[1])
            if fields[1] == "CONNECTED" {
                return fields[1]
            }
        }
    }

    public func disconnect() async throws {
        try await send("signal SIGTERM\n")
    }

    public func close() {
        connection.cancel()
    }
}
