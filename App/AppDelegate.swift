import AppKit
import VpngateShared

/// Defers app termination (Cmd+Q, Dock quit, the menu bar Quit button --
/// they all funnel through here) until an active VPN connection has been
/// torn down, so quitting the app doesn't strand the tunnel running under
/// the still-live privileged helper.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let helper = HelperClient.shared, helper.connectionState.phase != .disconnected else {
            return .terminateNow
        }
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await helper.disconnect() }
                group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
