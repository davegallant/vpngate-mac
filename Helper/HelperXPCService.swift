import Foundation
import VpngateShared

final class HelperXPCService: NSObject, VpngateHelperXPCProtocol {
    private let supervisor = OpenVPNSupervisor()
    private var recentLogs: [LogLine] = []
    private let maxRecentLogs = 200
    /// Tracks an in-flight `connect()` so `disconnect()` can stop it. Cancelling
    /// this Task propagates through the timeout-racing `withTimeout` calls in
    /// ManagementClient (their internal `Task.sleep` throws promptly on
    /// cancellation), which drives `connect()` into its own `catch` block and
    /// its existing `cleanUpAfterFailedConnect()` teardown. `disconnect()` must
    /// never call into `supervisor` concurrently with a still-running
    /// `connect()` -- OpenVPNSupervisor isn't an actor, so that would race on
    /// its process/managementClient state -- hence always awaiting this task's
    /// completion before doing anything else.
    private var connectTask: Task<Void, Never>?
    /// Identifies which `connect()` call a given Task belongs to, so that
    /// task's own "I'm done, clear connectTask" cleanup doesn't clobber a
    /// *newer* connectTask that superseded it while it was draining.
    private var connectGeneration = 0
    weak var connection: NSXPCConnection?

    override init() {
        super.init()
        supervisor.onStateChange = { [weak self] state in
            guard let self, let data = try? JSONEncoder().encode(state) else { return }
            let client = self.connection?.remoteObjectProxy as? VpngateHelperClientXPCProtocol
            client?.connectionStateDidChange(stateJSON: data)
        }
        supervisor.onLogLine = { [weak self] line in
            guard let self else { return }
            self.recentLogs.append(line)
            if self.recentLogs.count > self.maxRecentLogs {
                self.recentLogs.removeFirst(self.recentLogs.count - self.maxRecentLogs)
            }
            guard let data = try? JSONEncoder().encode(line) else { return }
            let client = self.connection?.remoteObjectProxy as? VpngateHelperClientXPCProtocol
            client?.didReceiveLogLine(lineJSON: data)
        }
    }

    func connect(serverJSON: Data, reply: @escaping (Data?) -> Void) {
        guard let server = try? JSONDecoder().decode(Server.self, from: serverJSON) else {
            let err = HelperOperationError(code: "invalidRequest", message: "malformed server payload")
            reply(try? JSONEncoder().encode(err))
            return
        }
        // A previous connect() may still be in flight (e.g. the user picked
        // a different server before the first attempt resolved). Letting
        // both run concurrently races on OpenVPNSupervisor's process/
        // managementClient state and orphans the first attempt's openvpn
        // process forever, since nothing else holds a reference to it once
        // supervisor.process is overwritten by the second call. Cancel and
        // fully drain the previous attempt (same teardown path disconnect()
        // already drives) before starting the new one.
        let previousTask = connectTask
        connectGeneration += 1
        let generation = connectGeneration
        connectTask = Task { [weak self] in
            if let previousTask {
                await self?.supervisor.debugLog("[stop] superseded by a new connect request, cancelling")
                previousTask.cancel()
                _ = await previousTask.value
            }
            await self?.supervisor.debugLog("[stop] connect task started")
            do {
                try await self?.supervisor.connect(to: server)
                reply(nil)
            } catch is CancellationError {
                await self?.supervisor.debugLog("[stop] connect task saw CancellationError, replying cancelled")
                let err = HelperOperationError(code: "cancelled", message: "connection attempt stopped")
                reply(try? JSONEncoder().encode(err))
            } catch let err as HelperOperationError {
                reply(try? JSONEncoder().encode(err))
            } catch {
                let wrapped = HelperOperationError(code: "connectFailed", message: error.localizedDescription)
                reply(try? JSONEncoder().encode(wrapped))
            }
            await self?.supervisor.debugLog("[stop] connect task finished")
            if self?.connectGeneration == generation {
                self?.connectTask = nil
            }
        }
    }

    func disconnect(reply: @escaping (Data?) -> Void) {
        // A connect() is still running -- cancel it and wait for its own
        // teardown to finish rather than calling supervisor.disconnect()
        // concurrently (see connectTask's doc comment).
        if let connectTask {
            Task { await supervisor.debugLog("[stop] disconnect() called while connecting, cancelling") }
            connectTask.cancel()
            Task {
                _ = await connectTask.value
                await supervisor.debugLog("[stop] cancelled connect task drained, replying to disconnect")
                reply(nil)
            }
            return
        }
        Task {
            do {
                try await supervisor.disconnect()
                reply(nil)
            } catch {
                let wrapped = HelperOperationError(code: "disconnectFailed", message: error.localizedDescription)
                reply(try? JSONEncoder().encode(wrapped))
            }
        }
    }

    func status(reply: @escaping (Data) -> Void) {
        let data = (try? JSONEncoder().encode(supervisor.currentState)) ?? Data()
        reply(data)
    }

    func fetchRecentLogs(tailLines: Int, reply: @escaping ([Data]) -> Void) {
        let tail = recentLogs.suffix(max(tailLines, 0))
        let encoded = tail.compactMap { try? JSONEncoder().encode($0) }
        reply(encoded)
    }
}
