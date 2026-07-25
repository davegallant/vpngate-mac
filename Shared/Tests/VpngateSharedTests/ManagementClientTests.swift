import XCTest
import Network
@testable import VpngateShared

/// Mimics OpenVPN's management interface: sends the greeting line on
/// connect, then calls onCommand for each line the client sends. Mirrors
/// pkg/daemon/management_test.go's startFakeManagementServer.
final class FakeManagementServer {
    private let listener: NWListener
    private var activeConnections: [NWConnection] = []
    private let onCommand: (String, NWConnection) -> Void

    /// `port`, when provided, binds the listener to that specific port
    /// instead of an ephemeral one -- used to simulate a peer that isn't
    /// listening yet (e.g. testing `connectWithRetry`'s recovery from an
    /// openvpn process that hasn't bound its management port yet).
    init(port: UInt16? = nil, onCommand: @escaping (String, NWConnection) -> Void) throws {
        self.onCommand = onCommand
        if let port {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw ManagementError.connectionFailed("invalid port \(port)")
            }
            self.listener = try NWListener(using: .tcp, on: nwPort)
        } else {
            self.listener = try NWListener(using: .tcp, on: .any)
        }
    }

    /// Starts the listener and waits until its ephemeral port is assigned.
    func startAndWaitForPort() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let guardOnce = ResumeOnceGuard()
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard guardOnce.tryResume() else { return }
                    continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard guardOnce.tryResume() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .utility))
        }
    }

    private func accept(_ connection: NWConnection) {
        activeConnections.append(connection)
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: .global(qos: .utility))
        connection.send(content: Data(">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info\n".utf8), completion: .contentProcessed { _ in })
        readLoop(connection, buffer: Data())
    }

    private func readLoop(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }
            while let range = buf.firstRange(of: Data([0x0A])) {
                let lineData = buf.subdata(in: buf.startIndex..<range.lowerBound)
                buf.removeSubrange(buf.startIndex..<range.upperBound)
                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                self.onCommand(line, connection)
            }
            if error == nil && !isComplete {
                self.readLoop(connection, buffer: buf)
            }
        }
    }

    func stop() {
        listener.cancel()
        activeConnections.forEach { $0.cancel() }
    }
}

final class ManagementClientTests: XCTestCase {
    func testState() async throws {
        let server = try FakeManagementServer { cmd, connection in
            if cmd == "state" {
                connection.send(content: Data("1690000000,CONNECTED,SUCCESS,10.9.0.2,1.2.3.4,1194,,\r\nEND\r\n".utf8), completion: .contentProcessed { _ in })
            }
        }
        let port = try await server.startAndWaitForPort()
        defer { server.stop() }

        let client = try await ManagementClient.connect(host: "127.0.0.1", port: port)
        let state = try await client.state()
        XCTAssertEqual(state, "CONNECTED")
        await client.close()
    }

    func testDisconnectSendsSignalSigterm() async throws {
        let receivedCommand = ActorBox<String?>(nil)
        let server = try FakeManagementServer { cmd, _ in
            Task { await receivedCommand.set(cmd) }
        }
        let port = try await server.startAndWaitForPort()
        defer { server.stop() }

        let client = try await ManagementClient.connect(host: "127.0.0.1", port: port)
        try await client.disconnect()

        // Poll briefly for the async fake-server callback to land.
        var observed: String?
        for _ in 0..<50 {
            observed = await receivedCommand.get()
            if observed != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(observed, "signal SIGTERM")
        await client.close()
    }

    func testParseStateNoStateLine() {
        XCTAssertThrowsError(try ManagementClient.parseState(["", "garbage-with-no-comma"])) { error in
            XCTAssertEqual(error as? ManagementError, .noStateFound)
        }
    }

    func testConnectRefused() async throws {
        do {
            _ = try await ManagementClient.connect(host: "127.0.0.1", port: 1, timeout: 1)
            XCTFail("expected connection to be refused")
        } catch {
            // Any ManagementError is acceptable here; the point is that it throws.
            XCTAssertTrue(error is ManagementError)
        }
    }

    func testManagementErrorDescriptions() {
        XCTAssertEqual(
            ManagementError.connectionFailed("boom").errorDescription,
            "Management connection failed: boom"
        )
        XCTAssertEqual(
            ManagementError.noStateFound.errorDescription,
            "No connection state reported by OpenVPN"
        )
        XCTAssertEqual(
            ManagementError.unexpectedClose.errorDescription,
            "Management connection closed unexpectedly"
        )
    }

    func testWaitForConnectedStateReachesConnectedAndReportsIntermediateStates() async throws {
        let server = try FakeManagementServer { cmd, connection in
            guard cmd == "state on" else { return }
            connection.send(content: Data("SUCCESS: real-time state notification set to ON\r\n".utf8), completion: .contentProcessed { _ in })
            connection.send(content: Data(">STATE:1690000000,CONNECTING,,,,,,\r\n".utf8), completion: .contentProcessed { _ in })
            connection.send(content: Data(">STATE:1690000001,CONNECTED,SUCCESS,10.9.0.2,1.2.3.4,1194,,\r\n".utf8), completion: .contentProcessed { _ in })
        }
        let port = try await server.startAndWaitForPort()
        defer { server.stop() }

        let client = try await ManagementClient.connect(host: "127.0.0.1", port: port)
        let log = StateLog()

        let final = try await client.waitForConnectedState(timeout: 5) { _ in
        } onUpdate: { state in
            Task { await log.record(state) }
        }
        XCTAssertEqual(final, "CONNECTED")

        // The onUpdate calls are dispatched via Task{} (StateLog is an actor),
        // so poll briefly rather than assuming they've landed the instant
        // waitForConnectedState returns.
        var states: [String] = []
        for _ in 0..<50 {
            states = await log.states
            if states.count >= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(states, ["CONNECTING", "CONNECTED"])
        await client.close()
    }

    func testWaitForConnectedStateTimesOutWithoutConnectedPush() async throws {
        let server = try FakeManagementServer { cmd, connection in
            guard cmd == "state on" else { return }
            // Confirms the mode switch but never pushes a CONNECTED state.
            connection.send(content: Data("SUCCESS: real-time state notification set to ON\r\n".utf8), completion: .contentProcessed { _ in })
        }
        let port = try await server.startAndWaitForPort()
        defer { server.stop() }

        let client = try await ManagementClient.connect(host: "127.0.0.1", port: port)
        do {
            _ = try await client.waitForConnectedState(timeout: 0.3)
            XCTFail("expected a timeout error")
        } catch ManagementError.connectionFailed(let message) {
            XCTAssertEqual(message, "timed out waiting for CONNECTED state")
        }
        await client.close()
    }

    func testWaitForConnectedStateSurvivesAPerReadTimeoutWhileWaitingForConnected() async throws {
        // Sends SUCCESS immediately, then a CONNECTED push after a delay
        // that spans multiple 0.2s per-read windows -- proving the "nothing
        // arrived in this window, keep waiting" retry in
        // waitForConnectedState's `catch
        // ManagementError.connectionFailed("timed out") { continue }` arm
        // doesn't disturb the still-healthy connection or drop the later
        // push once it finally arrives. Real connects hit this same arm
        // (each push can be seconds apart, well inside the 60s deadline but
        // outside any single per-read window).
        let server = try FakeManagementServer { cmd, connection in
            guard cmd == "state on" else { return }
            connection.send(content: Data("SUCCESS: real-time state notification set to ON\r\n".utf8), completion: .contentProcessed { _ in })
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                connection.send(content: Data(">STATE:1690000001,CONNECTED,SUCCESS,10.9.0.2,1.2.3.4,1194,,\r\n".utf8), completion: .contentProcessed { _ in })
            }
        }
        let port = try await server.startAndWaitForPort()
        defer { server.stop() }

        let client = try await ManagementClient.connect(host: "127.0.0.1", port: port)
        let final = try await client.waitForConnectedState(timeout: 3, perReadTimeout: 0.2)
        XCTAssertEqual(final, "CONNECTED")
        await client.close()
    }

    func testWaitForConnectedStateThrowsCancellationErrorWhenCancelled() async throws {
        let receivedStateOn = ActorBox<Bool>(false)
        let server = try FakeManagementServer { cmd, _ in
            if cmd == "state on" {
                Task { await receivedStateOn.set(true) }
            }
        }
        let port = try await server.startAndWaitForPort()
        defer { server.stop() }

        let client = try await ManagementClient.connect(host: "127.0.0.1", port: port)
        let waitTask = Task {
            try await client.waitForConnectedState(timeout: 10)
        }

        for _ in 0..<100 {
            if await receivedStateOn.get() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        waitTask.cancel()

        do {
            _ = try await waitTask.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        await client.close()
    }

    func testConnectWithRetryRecoversFromInitialRefusal() async throws {
        // Reserve then release a loopback port so we know a fixed port
        // number that's currently free, then only start listening on it
        // after a short delay -- mirroring the real startup race between
        // the helper dialing the management port and openvpn having bound
        // it yet.
        let port = try PortReservation.reserveLoopbackPort()
        let serverBox = ActorBox<FakeManagementServer?>(nil)

        let startTask = Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            let server = try FakeManagementServer(port: port) { cmd, connection in
                if cmd == "state" {
                    connection.send(content: Data("1690000000,CONNECTED,SUCCESS,10.9.0.2,1.2.3.4,1194,,\r\nEND\r\n".utf8), completion: .contentProcessed { _ in })
                }
            }
            _ = try await server.startAndWaitForPort()
            await serverBox.set(server)
        }

        let client = try await ManagementClient.connectWithRetry(
            host: "127.0.0.1",
            port: port,
            perAttemptTimeout: 0.3,
            retryInterval: 0.1,
            overallTimeout: 5
        )
        let state = try await client.state()
        XCTAssertEqual(state, "CONNECTED")

        await client.close()
        try await startTask.value
        await serverBox.get()?.stop()
    }
}

/// Collects states reported via `waitForConnectedState`'s `onUpdate`
/// callback -- an actor since that callback is `@Sendable` and may be
/// invoked from a different isolation context than the test itself.
actor StateLog {
    private(set) var states: [String] = []
    func record(_ state: String) { states.append(state) }
}

/// Minimal actor-based box for shuttling a value out of a fake server's
/// synchronous callback into an async test.
actor ActorBox<T> {
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { value = newValue }
    func get() -> T { value }
}
