import XCTest
@testable import XperiaRescueCore

/// Transcript fragments below are copied from the prompts in newflasher.c (v61).
final class NewflasherTests: XCTestCase {
    private let userdataPrompt = "\nDo you want to keep userdata? Type 'y' and press ENTER to confirm, or type 'n' to erase userdata.\n"
    private let rebootPrompt = "\nReboot mode at the end of flashing:\n  type 'a' for reboot to android, type 'f' for reboot to fastboot, type 'd' for reboot to fastbootd, type 'r' for reboot to recovery, type 's' for reboot to same mode, type 'p' for poweroff, and press ENTER.\n"
    private let taPrompt = "\nOptional step! Type 'y' and press ENTER if you want dump trim area, or type 'n' and press ENTER to skip.\nDo in mind this doesn't dump drm key since sake authentifiction is need for that! But it is recommend to have dump in case hard brick!\n"
    private let batteryPrompt = "\nYour battery level is 9 percent and you have risk for hard brick in case your battery get fully discharged durring flash session!\nType 'y' and press ENTER if you understand the risk, or type 'n' to exit from flashing.\n"

    func testAnswersKnownPromptsFromOptions() {
        var responder = NewflasherPromptResponder(options: NewflasherOptions(keepUserData: true, rebootMode: .android, backUpTrimArea: true, allowLowBattery: false))
        let answers = responder.feed(userdataPrompt + rebootPrompt + taPrompt + batteryPrompt)
        XCTAssertEqual(answers, [
            NewflasherPromptAnswer(prompt: .keepUserData, answer: "y"),
            NewflasherPromptAnswer(prompt: .rebootMode, answer: "a"),
            NewflasherPromptAnswer(prompt: .dumpTrimArea, answer: "y"),
            NewflasherPromptAnswer(prompt: .lowBattery(level: 9), answer: "n"),
        ])
    }

    func testOppositeOptions() {
        var responder = NewflasherPromptResponder(options: NewflasherOptions(keepUserData: false, rebootMode: .powerOff, backUpTrimArea: false, allowLowBattery: true))
        let answers = responder.feed(userdataPrompt + rebootPrompt + taPrompt + batteryPrompt).map(\.answer)
        XCTAssertEqual(answers, ["n", "p", "n", "y"])
    }

    func testPromptsSplitAcrossChunksAreAnsweredOnce() {
        var responder = NewflasherPromptResponder(options: NewflasherOptions())
        let transcript = "----\n newflasher v61\n" + rebootPrompt + "Device properties:\n" + taPrompt
        var answers: [NewflasherPromptAnswer] = []
        // Feed in awkward 7-character chunks.
        var index = transcript.startIndex
        while index < transcript.endIndex {
            let end = transcript.index(index, offsetBy: 7, limitedBy: transcript.endIndex) ?? transcript.endIndex
            answers += responder.feed(String(transcript[index..<end]))
            index = end
        }
        XCTAssertEqual(answers.map(\.prompt), [.rebootMode, .dumpTrimArea])
    }

    func testUnknownPromptNeedsUser() {
        var responder = NewflasherPromptResponder(options: NewflasherOptions())
        let answers = responder.feed("Type 'y' and press ENTER to flash the frobnicator.\n")
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(answers[0].answer)
        XCTAssertEqual(answers[0].prompt, .unknown("Type 'y' and press ENTER to flash the frobnicator."))
    }

    func testNoAnswerUntilLineComplete() {
        var responder = NewflasherPromptResponder(options: NewflasherOptions())
        XCTAssertTrue(responder.feed("Do you want to keep userdata? Type 'y' and press ENTER").isEmpty)
        XCTAssertEqual(responder.feed(" to confirm, or type 'n' to erase userdata.\n").map(\.prompt), [.keepUserData])
    }

    func testGordonGatePromptIsDeclined() {
        var responder = NewflasherPromptResponder(options: NewflasherOptions())
        let answers = responder.feed("\nOptional step! Type 'y' and press ENTER if you need GordonGate flash driver, or type 'n' to skip.\nThis creates GordonGate driver installer in the same dir with newflasher!\n")
        XCTAssertEqual(answers, [NewflasherPromptAnswer(prompt: .gordonGateDriver, answer: "n")])
    }

    func testAnalyzerParsesDeviceInfoProgressAndCompletion() {
        var analyzer = NewflasherOutputAnalyzer()
        let output = """
        Product: XQ-DE54
        Version: 67.2.A.3.194
        Battery level: 63
        Current slot: a
        Rooting status: NOT_ROOTABLE

        Processing boot_X-FLASH-ALL-B6B5.sin
         Chunk 1 [=====     ] 50.00%\r Chunk 1 [==========] 100.00%
        Processing super_X-FLASH-ALL-C934.sin
        Skipping userdata_X-FLASH-CUST-C934.sin
         - Skipping persist_X-FLASH-ALL-AAAA.sin
        Sent command: continue.

        Done.

        """
        let events = analyzer.feed(output)
        XCTAssertEqual(analyzer.deviceModel, "XQ-DE54")
        XCTAssertEqual(analyzer.batteryLevel, 63)
        XCTAssertEqual(analyzer.deviceInfo["Current slot"], "a")
        XCTAssertEqual(analyzer.processedFiles, ["boot_X-FLASH-ALL-B6B5.sin", "super_X-FLASH-ALL-C934.sin"])
        XCTAssertEqual(analyzer.skippedFiles, ["userdata_X-FLASH-CUST-C934.sin", "persist_X-FLASH-ALL-AAAA.sin"])
        XCTAssertTrue(analyzer.didFinish)
        XCTAssertTrue(events.contains(.finished))
        XCTAssertTrue(analyzer.problems.isEmpty, "\(analyzer.problems)")
    }

    func testAnalyzerExplainsCommonFailures() {
        var analyzer = NewflasherOutputAnalyzer()
        _ = analyzer.feed("\nNo usb device with vid:0x0fce pid:0xb00b !\n")
        _ = analyzer.feed("Claiming interface 0: failed with error: LIBUSB_ERROR_ACCESS\n")
        _ = analyzer.feed("  Error! You do not have needed 10240 MB available free space on your\n")
        XCTAssertEqual(analyzer.problems.count, 3)
        XCTAssertTrue(analyzer.problems[0].hint.contains("flash mode"))
        XCTAssertTrue(analyzer.problems[1].hint.contains("USB"))
        XCTAssertTrue(analyzer.problems[2].hint.contains("10 GB"))
    }

    func testAnalyzerTrimAreaAndUnterminatedLine() {
        var analyzer = NewflasherOutputAnalyzer()
        XCTAssertEqual(analyzer.feed("Dumping trim area to tadump folder.\n"), [.trimAreaDumped])
        XCTAssertTrue(analyzer.feed("Done.").isEmpty)
        XCTAssertEqual(analyzer.finish(), [.finished])
    }

    /// Excerpt of a real session on a pre-production Xperia 5 V (newflasher v61, keep userdata).
    func testRealDevelopmentUnitSession() {
        let log = """
        Trim area dump done, continuing with flashing.
        Product: XQ-DE54
        Version: 0.4
        Secure: no
        Rooting status: ROOTED
        Emmc info: FAILEmmc-info not supported
        Default security: OFF
        S1 root: S1_Root_d831,S1_Root_Test_b316
        Slot count: 2
        Current slot: b
        Battery level: 0 unsupported command
        CDFId: (null)

        Repartitioning...
        Processing partition-image-LUN0_124887040_X-FLASH-ALL-25B1.sin
         - End of partition-image-LUN0_124887040_X-FLASH-ALL-25B1.sin

        Processing partition-image-LUN0_249847808_X-FLASH-ALL-25B1.sin
        Skipping partition-image-LUN0_249847808_X-FLASH-ALL-25B1.sin

        Processing .sin files...
        Processing misc_X-FLASH-ALL-25B1.sin
         - End of misc_X-FLASH-ALL-25B1.sin

        Processing userdata_X-FLASH-ALL-25B1.sin
        <NOERASE>userdata_X-FLASH-ALL-25B1.sin</NOERASE>
         - Skipping userdata_X-FLASH-ALL-25B1.sin
        Skipping persist_X-FLASH-ALL-25B1.sin

        Processing .ta files...
        Processing auto-boot.ta
        Processing boot delivery...
        Processing ./boot/PDX237_XBootConfig_MiscTA.ta
        Processing bootloader_111_X-FLASH-ALL-7430.sin
         - End of bootloader_111_X-FLASH-ALL-7430.sin

        Set slot 'b' active.
        Sent command: continue.

        Done.

        """
        var analyzer = NewflasherOutputAnalyzer()
        _ = analyzer.feed(log)
        XCTAssertEqual(analyzer.deviceModel, "XQ-DE54")
        XCTAssertNil(analyzer.batteryLevel, "0 unsupported command must not read as 0 %")
        XCTAssertEqual(analyzer.currentSlot, "b")
        XCTAssertTrue(analyzer.isDevelopmentUnit)
        XCTAssertEqual(analyzer.isBootloaderUnlocked, true)
        XCTAssertEqual(analyzer.processedFiles, [
            "partition-image-LUN0_124887040_X-FLASH-ALL-25B1.sin",
            "partition-image-LUN0_249847808_X-FLASH-ALL-25B1.sin",
            "misc_X-FLASH-ALL-25B1.sin",
            "userdata_X-FLASH-ALL-25B1.sin",
            "bootloader_111_X-FLASH-ALL-7430.sin",
        ])
        XCTAssertEqual(analyzer.flashedImages, [
            "partition-image-LUN0_124887040_X-FLASH-ALL-25B1.sin",
            "misc_X-FLASH-ALL-25B1.sin",
            "bootloader_111_X-FLASH-ALL-7430.sin",
        ])
        XCTAssertTrue(analyzer.didFinish)
        XCTAssertTrue(analyzer.problems.isEmpty, "\(analyzer.problems)")
    }

    func testRetailUnitIsNotDevelopment() {
        var analyzer = NewflasherOutputAnalyzer()
        _ = analyzer.feed("Rooting status: ROOTABLE\nDefault security: ON\nS1 root: S1_Root_d831\nBattery level: 57\n")
        XCTAssertFalse(analyzer.isDevelopmentUnit)
        XCTAssertEqual(analyzer.isBootloaderUnlocked, false)
        XCTAssertEqual(analyzer.batteryLevel, 57)
    }

    func testNoTrimAreaWarningIsNotAProblem() {
        var analyzer = NewflasherOutputAnalyzer()
        _ = analyzer.feed("\nNo trim area dump taken, continuing with flashing anyway. If this phone ever hard bricks there will be no trim area backup to restore from, and that is on you.\n")
        XCTAssertTrue(analyzer.problems.isEmpty)
    }
}
