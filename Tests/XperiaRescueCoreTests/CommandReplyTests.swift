import XCTest
@testable import XperiaRescueCore

final class CommandReplyTests: XCTestCase {
    /// Reproduces newflasher's display_buffer_hex_ascii() output for a reply.
    private func dump(_ reply: String, message: String = "got first reply") -> String {
        let bytes = Array(reply.utf8)
        var out = "\(message)[0x\(String(bytes.count, radix: 16, uppercase: true))]:\n"
        var i = 0
        while i < bytes.count {
            out += "\n  " + String(format: "%08X", i) + "  "
            for k in 0..<16 {
                out += i + k < bytes.count ? String(format: "%02X", bytes[i + k]) : "  "
                out += " "
            }
            out += " "
            for k in 0..<16 where i + k < bytes.count {
                let c = bytes[i + k]
                out += (c < 32 || c > 126) ? "." : String(UnicodeScalar(c))
            }
            i += 16
        }
        return out + "\n\n"
    }

    private func transcript(_ command: String, reply: String) -> String {
        """
        --------------------------------------------------------
                    newflasher v61 by Munjeni @ 2017/2026
        --------------------------------------------------------

        Reading string descriptors:
           String (0x01): "Google"
           String (0x02): "Android"


        update.xml not exist in current folder!
        Writing command: \(command)
        \(dump(reply))Releasing interface 0.
        Closing device.

        """
    }

    func testSingleCharacterReply() {
        XCTAssertEqual(NewflasherCommandReply.parse(transcript("getvar:current-slot", reply: "b")), .okay("b"))
    }

    func testShortAndMultiRowReplies() {
        XCTAssertEqual(NewflasherCommandReply.parse(transcript("getvar:product", reply: "XQ-DE54")), .okay("XQ-DE54"))
        // 30 bytes: spans two dump rows.
        XCTAssertEqual(
            NewflasherCommandReply.parse(transcript("getvar:S1-root", reply: "S1_Root_d831,S1_Root_Test_b316")),
            .okay("S1_Root_d831,S1_Root_Test_b316")
        )
        // A value made of hex-looking characters must not bleed into the ASCII column.
        XCTAssertEqual(NewflasherCommandReply.parse(transcript("getvar:x", reply: "AB CD EF 0123456")), .okay("AB CD EF 0123456"))
    }

    func testBareOkayAndFailures() {
        XCTAssertEqual(NewflasherCommandReply.parse(transcript("set_active:a", reply: "OKAY")), .okay(""))
        XCTAssertEqual(NewflasherCommandReply.parse("Writing command: getvar:nope\ngot fail reply: FAILunknown variable\n"), .failed("FAILunknown variable"))
        XCTAssertEqual(NewflasherCommandReply.parse("\nNo usb device with vid:0x0fce pid:0xb00b !\n"), .none)
    }
}
