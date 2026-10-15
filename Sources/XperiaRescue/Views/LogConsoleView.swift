import AppKit
import SwiftUI

struct LogConsoleView: View {
    @ObservedObject var log: LogStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Log", systemImage: "text.alignleft").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.fullText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    save()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                Button {
                    log.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            LogTextView(text: log.text)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xperia-rescue-log-\(AppModel.timestamp()).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? log.fullText.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// NSTextView keeps a long, fast-changing log responsive and selectable.
struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textColor = .textColor
            textView.backgroundColor = .textBackgroundColor
        }
        scrollView.hasVerticalScroller = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        let clipBounds = scrollView.contentView.bounds
        let wasAtBottom = clipBounds.maxY >= textView.bounds.maxY - 30
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .textColor
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}
