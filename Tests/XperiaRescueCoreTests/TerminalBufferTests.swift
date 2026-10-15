import XCTest
@testable import XperiaRescueCore

final class TerminalBufferTests: XCTestCase {
    func testCarriageReturnOverwritesLine() {
        var buffer = TerminalBuffer()
        buffer.append("Processing boot.sin\n 10%\r 50%\r100%\nnext")
        XCTAssertEqual(buffer.allLines, ["Processing boot.sin", "100%", "next"])
    }

    func testCRLFIsOneNewlineEvenAcrossChunks() {
        var buffer = TerminalBuffer()
        buffer.append("a\r")
        buffer.append("\nb\r\nc")
        XCTAssertEqual(buffer.allLines, ["a", "b", "c"])
    }

    func testStripsANSIAndHandlesBackspace() {
        var buffer = TerminalBuffer()
        buffer.append("\u{1B}[1;32mOKAY\u{1B}[0m\nab\u{08}c\n")
        XCTAssertEqual(buffer.lines, ["OKAY", "ac"])
    }

    func testMaxLines() {
        var buffer = TerminalBuffer(maxLines: 3)
        for i in 0..<10 { buffer.appendLine("line \(i)") }
        XCTAssertEqual(buffer.lines, ["line 7", "line 8", "line 9"])
    }

    func testUTF8DecoderHandlesSplitSequences() {
        var decoder = UTF8StreamDecoder()
        let bytes = Array("✓ done › ok".utf8)
        var output = ""
        for byte in bytes { output += decoder.decode(Data([byte])) }
        output += decoder.flush()
        XCTAssertEqual(output, "✓ done › ok")
    }
}
