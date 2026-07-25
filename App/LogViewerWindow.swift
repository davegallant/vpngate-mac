import AppKit
import SwiftUI
import VpngateShared

struct LogViewerView: View {
    @EnvironmentObject var helper: HelperClient
    @State private var lines: [LogLine] = []

    var body: some View {
        VStack(spacing: 0) {
            LogTextView(text: lines.map(\.text).joined(separator: "\n"))

            Divider()

            HStack {
                Spacer()
                Button("Clear") { lines.removeAll() }
                Button("Copy") { copyToPasteboard() }
            }
            .padding(8)
        }
        .frame(minWidth: 500, minHeight: 300)
        .task {
            lines = await helper.fetchRecentLogs(tailLines: 200)
            for await line in helper.logLines {
                lines.append(line)
                if lines.count > 1000 {
                    lines.removeFirst(lines.count - 1000)
                }
            }
        }
    }

    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
    }
}

/// Backed by `NSTextView` rather than a SwiftUI `Text` -- `Text` re-lays-out
/// its entire string on every mutation, which visibly lagged once the log
/// reached a few hundred lines. This appends only the new suffix instead,
/// and gets natural multi-line text selection for free.
private struct LogTextView: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard text != coordinator.lastText else { return }

        let wasAtBottom = isScrolledToBottom(scrollView)

        if text.hasPrefix(coordinator.lastText) {
            let suffix = String(text.dropFirst(coordinator.lastText.count))
            textView.textStorage?.append(NSAttributedString(
                string: suffix,
                attributes: [.font: textView.font as Any, .foregroundColor: NSColor.textColor]
            ))
        } else {
            // Cleared, or the front got trimmed (1000-line cap) -- the new
            // text isn't a simple extension of the old, so rewrite it all.
            textView.string = text
        }
        coordinator.lastText = text

        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastText = ""
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        return scrollView.contentView.bounds.maxY >= documentView.frame.height - 4
    }
}
