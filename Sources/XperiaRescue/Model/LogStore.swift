import Foundation
import XperiaRescueCore

/// The shared console. Kept separate from AppModel so that streaming output
/// only re-renders the console, and throttled to ~10 updates per second.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var text = ""

    private var buffer = TerminalBuffer(maxLines: 8_000)
    private var updateScheduled = false

    var fullText: String { buffer.text }

    func append(_ output: String) {
        buffer.append(output)
        scheduleUpdate()
    }

    func appendLine(_ line: String) {
        buffer.appendLine(line)
        scheduleUpdate()
    }

    func clear() {
        buffer.clear()
        text = ""
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.updateScheduled = false
            self.text = self.buffer.text
        }
    }
}
