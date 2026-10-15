import Foundation

/// Decodes UTF-8 from a byte stream whose chunks may split multi-byte characters.
public struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func decode(_ data: Data) -> String {
        pending.append(contentsOf: data)
        // Find the longest prefix that does not end inside a multi-byte sequence.
        var cut = pending.count
        var index = pending.count - 1
        var lookback = 0
        while index >= 0 && lookback < 4 {
            let byte = pending[index]
            if byte & 0b1100_0000 == 0b1000_0000 { // continuation byte
                index -= 1
                lookback += 1
                continue
            }
            let needed: Int
            if byte & 0b1000_0000 == 0 { needed = 1 }
            else if byte & 0b1110_0000 == 0b1100_0000 { needed = 2 }
            else if byte & 0b1111_0000 == 0b1110_0000 { needed = 3 }
            else if byte & 0b1111_1000 == 0b1111_0000 { needed = 4 }
            else { needed = 1 } // invalid lead byte; let the decoder replace it
            if pending.count - index < needed { cut = index }
            break
        }
        let complete = Array(pending[..<cut])
        pending.removeFirst(cut)
        return String(decoding: complete, as: UTF8.self)
    }

    /// Returns whatever is left (replacing incomplete sequences).
    public mutating func flush() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// A scrollback buffer that behaves like a terminal for `\r` progress bars:
/// a carriage return rewinds the current line instead of starting a new one.
public struct TerminalBuffer {
    public private(set) var lines: [String] = []
    public private(set) var currentLine = ""
    public let maxLines: Int
    private var pendingCarriageReturn = false

    public init(maxLines: Int = 10_000) {
        self.maxLines = maxLines
    }

    public var allLines: [String] {
        currentLine.isEmpty ? lines : lines + [currentLine]
    }

    public var text: String { allLines.joined(separator: "\n") }

    public mutating func append(_ rawText: String) {
        let text = Self.stripANSI(rawText)
        for scalar in text.unicodeScalars {
            if pendingCarriageReturn {
                pendingCarriageReturn = false
                if scalar == "\n" {
                    commitLine()
                    continue
                }
                currentLine = ""
            }
            switch scalar {
            case "\n":
                commitLine()
            case "\r":
                pendingCarriageReturn = true
            case "\u{08}": // backspace
                if !currentLine.isEmpty { currentLine.removeLast() }
            default:
                currentLine.unicodeScalars.append(scalar)
            }
        }
    }

    /// Adds a whole line, e.g. a message from the app itself.
    public mutating func appendLine(_ line: String) {
        if !currentLine.isEmpty { commitLine() }
        currentLine = line
        commitLine()
    }

    public mutating func clear() {
        lines.removeAll()
        currentLine = ""
        pendingCarriageReturn = false
    }

    private mutating func commitLine() {
        lines.append(currentLine)
        currentLine = ""
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
