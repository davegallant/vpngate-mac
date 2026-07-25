import AppKit
import SwiftUI
import VpngateShared

@main
struct VpngateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var helper = HelperClient()
    @StateObject private var serverList = ServerListStore()

    /// `.renderingMode(.original)` on a SwiftUI `Image` doesn't stop
    /// `NSStatusItem` from auto-templating an SF Symbol -- it still gets
    /// forced to a monochrome silhouette that ignores foregroundColor. Baking
    /// the color into the NSImage itself via SymbolConfiguration and marking
    /// it non-template is what actually shows color in the menu bar.
    private var statusIcon: NSImage {
        let color: NSColor = helper.connectionState.phase == .connected ? .systemGreen : .labelColor
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: "door.garage.closed", accessibilityDescription: "Vpngate")!
            .withSymbolConfiguration(config)!
        image.isTemplate = false
        return image
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(helper)
                .environmentObject(serverList)
        } label: {
            Image(nsImage: statusIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Vpngate Logs", id: "logs") {
            LogViewerView()
                .environmentObject(helper)
        }
    }
}
