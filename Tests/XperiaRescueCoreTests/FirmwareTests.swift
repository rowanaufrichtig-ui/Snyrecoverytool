import XCTest
@testable import XperiaRescueCore

final class FirmwareTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fwtests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let bootDelivery = """
    <?xml version="1.0" encoding="UTF-8"?>
    <BOOT_DELIVERY SPACE_ID="1325-7771" VERSION="X_Boot_SDM8550">
      <CONFIGURATION NAME="PDX237_A">
        <ATTRIBUTES VALUE="PLATFORM_ID=&quot;0x0021B0E1&quot;" />
        <HWCONFIG REVISION="1" />
        <BOOT_CONFIG><FILE PATH="PDX237_A_bootconfig.ta" /></BOOT_CONFIG>
        <BOOT_IMAGES>
          <FILE PATH="xbl_PDX237_A.sin" />
          <FILE PATH="abl_PDX237_A.sin" />
          <FILE PATH="tz_PDX237_A.sin" />
        </BOOT_IMAGES>
      </CONFIGURATION>
      <CONFIGURATION NAME="PDX237_B">
        <ATTRIBUTES VALUE="PLATFORM_ID=&quot;0x0021B0E2&quot;" />
        <BOOT_IMAGES>
          <FILE PATH="xbl_PDX237_B.sin" />
          <FILE PATH="abl_PDX237_B.sin" />
        </BOOT_IMAGES>
      </CONFIGURATION>
    </BOOT_DELIVERY>
    """

    private let updateXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <UPDATE>
      <NOERASE>userdata_X-FLASH-CUST-C934.sin</NOERASE>
      <NOERASE>reset-non-secure-adb.ta</NOERASE>
    </UPDATE>
    """

    private func makeFirmware(named name: String, update: Bool = true, boot: Bool = true, fwinfo: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["boot_X-FLASH-ALL-B6B5.sin", "super_X-FLASH-ALL-C934.sin", "vbmeta_X-FLASH-ALL-B6B5.sin",
                     "userdata_X-FLASH-CUST-C934.sin", "persist_X-FLASH-ALL-AAAA.sin", "Partition-image_X-FLASH-ALL.sin"] {
            try Data(repeating: 1, count: 1024).write(to: folder.appendingPathComponent(file))
        }
        try Data().write(to: folder.appendingPathComponent("reset-non-secure-adb.ta"))
        if update { try updateXML.write(to: folder.appendingPathComponent("update.xml"), atomically: true, encoding: .utf8) }
        if let fwinfo { try fwinfo.write(to: folder.appendingPathComponent("fwinfo.xml"), atomically: true, encoding: .utf8) }
        if boot {
            let bootFolder = folder.appendingPathComponent("boot", isDirectory: true)
            try FileManager.default.createDirectory(at: bootFolder, withIntermediateDirectories: true)
            try bootDelivery.write(to: bootFolder.appendingPathComponent("boot_delivery.xml"), atomically: true, encoding: .utf8)
            for file in ["xbl_PDX237_A.sin", "abl_PDX237_A.sin", "tz_PDX237_A.sin", "xbl_PDX237_B.sin", "abl_PDX237_B.sin"] {
                try Data(repeating: 2, count: 512).write(to: bootFolder.appendingPathComponent(file))
            }
        }
        return folder
    }

    func testInspectsCompleteXperiFirmFolder() throws {
        let folder = try makeFirmware(named: "XQ-DE54_Customized UK_67.2.A.3.194_R3C")
        let package = FirmwareInspector.inspect(folder: folder, availableBytes: 50 * 1_073_741_824)

        XCTAssertEqual(package.model, "XQ-DE54")
        XCTAssertEqual(package.version, "67.2.A.3.194")
        XCTAssertEqual(package.market, "Customized UK")
        XCTAssertEqual(package.sinFiles.count, 6)
        XCTAssertEqual(package.bootSinCount, 5)
        XCTAssertEqual(package.bootImagesPerConfiguration, 3)
        XCTAssertTrue(package.hasBootDelivery)
        XCTAssertTrue(package.supportsKeepingUserData)
        XCTAssertEqual(package.noEraseFiles, ["userdata_X-FLASH-CUST-C934.sin", "reset-non-secure-adb.ta"])
        XCTAssertEqual(package.taFiles, ["reset-non-secure-adb.ta"])
        XCTAssertEqual(package.totalBytes, 6 * 1024 + 5 * 512)
        XCTAssertFalse(package.hasErrors, "\(package.issues)")

        let persist = package.sinFiles.first { $0.partition == "persist" }
        XCTAssertEqual(persist?.alwaysSkipped, .persist)
        XCTAssertEqual(package.sinFiles.first { $0.name.hasPrefix("Partition") }?.alwaysSkipped, .partitionTable)
        XCTAssertEqual(package.sinFiles.first { $0.partition == "userdata" }?.erasesUserData, true)

        // 6 sins - persist - top-level partition image = 4, plus 3 boot images
        // (NOERASE files are still announced by newflasher when user data is kept).
        XCTAssertEqual(package.estimatedFlashSteps, 7)

        XCTAssertEqual(package.compatibility(withDeviceModel: "XQ-DE54"), .match)
        XCTAssertEqual(package.compatibility(withDeviceModel: "XQ_DE54"), .match)
        XCTAssertEqual(package.compatibility(withDeviceModel: "XQ-DE72"), .differentVariant(firmware: "XQ-DE54", device: "XQ-DE72"))
        XCTAssertEqual(package.compatibility(withDeviceModel: "XQ-DQ54"), .wrongDevice(firmware: "XQ-DE54", device: "XQ-DQ54"))
        XCTAssertEqual(package.compatibility(withDeviceModel: nil), .unknownDevice)
    }

    func testFwinfoTakesPrecedenceOverFolderName() throws {
        let folder = try makeFirmware(named: "my firmware", fwinfo: "<fwInfo><model>XQ-DE72</model><release>67.2.A.3.178</release><cda>1328-1234</cda></fwInfo>")
        let package = FirmwareInspector.inspect(folder: folder)
        XCTAssertEqual(package.model, "XQ-DE72")
        XCTAssertEqual(package.version, "67.2.A.3.178")
        XCTAssertEqual(package.cda, "1328-1234")
        XCTAssertTrue(package.issues.contains { $0.severity == .info && $0.message.contains("67.2.A.3.194") }, "older build should be flagged")
    }

    func testWrongDeviceFirmwareIsAnError() throws {
        let folder = try makeFirmware(named: "XQ-DQ54_Customized EU_68.1.A.2.170_R6C")
        let package = FirmwareInspector.inspect(folder: folder)
        XCTAssertEqual(package.model, "XQ-DQ54")
        XCTAssertTrue(package.hasErrors)
    }

    func testMissingPiecesProduceWarnings() throws {
        let folder = try makeFirmware(named: "renamed", update: false, boot: false)
        let package = FirmwareInspector.inspect(folder: folder)
        XCTAssertNil(package.model)
        XCTAssertFalse(package.hasErrors)
        XCTAssertFalse(package.supportsKeepingUserData)
        let warnings = package.issues.filter { $0.severity == .warning }.map(\.message)
        XCTAssertEqual(warnings.count, 3, "\(warnings)")
        XCTAssertEqual(package.compatibility(withDeviceModel: "XQ-DE54"), .unknownFirmware)
    }

    func testEmptyAndArchiveFolders() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertTrue(FirmwareInspector.inspect(folder: empty).hasErrors)

        try Data().write(to: empty.appendingPathComponent("XQ-DE54.zip"))
        let package = FirmwareInspector.inspect(folder: empty)
        XCTAssertTrue(package.issues.first?.message.contains("Extract") ?? false)

        XCTAssertTrue(FirmwareInspector.inspect(folder: root.appendingPathComponent("missing")).hasErrors)
    }

    func testLowDiskSpaceIsAnError() throws {
        let folder = try makeFirmware(named: "XQ-DE54_Customized EU_67.2.A.3.194_R2C")
        let package = FirmwareInspector.inspect(folder: folder, availableBytes: 3 * 1_073_741_824)
        XCTAssertTrue(package.hasErrors)
    }

    func testHelpers() {
        XCTAssertEqual(FirmwareInspector.partitionName(fromSinFile: "vendor_boot_X-FLASH-ALL-B6B5.sin"), "vendor_boot")
        XCTAssertEqual(FirmwareInspector.partitionName(fromSinFile: "modem.sin"), "modem")
        XCTAssertEqual(FirmwareInspector.extractModel(from: "fw for so-53d docomo"), "SO-53D")
        XCTAssertEqual(FirmwareInspector.extractModel(from: "SOG12_au_67.2.A.3.91"), "SOG12")
        XCTAssertNil(FirmwareInspector.extractModel(from: "XQ-DE5"))
        XCTAssertEqual(FirmwareInspector.extractVersion(from: "build 67.2.A.3.194-R3C"), "67.2.A.3.194")
        XCTAssertNil(FirmwareInspector.extractVersion(from: "1.2.3"))
        XCTAssertEqual(FirmwareInspector.compareFirmwareVersions("67.2.A.3.91", "67.2.A.3.194"), .orderedAscending)
        XCTAssertEqual(FirmwareInspector.compareFirmwareVersions("67.2.A.3.194", "67.2.A.3.194"), .orderedSame)
        XCTAssertEqual(FirmwareInspector.compareFirmwareVersions("68.0.A.1.1", "67.2.A.3.194"), .orderedDescending)
    }

    func testPreflight() throws {
        let folder = try makeFirmware(named: "XQ-DE54_Customized UK_67.2.A.3.194_R3C")
        let package = FirmwareInspector.inspect(folder: folder)
        var input = PreflightInput(newflasherAvailable: true, firmware: package, usbMode: .flashMode, deviceModel: "XQ-DE54", options: NewflasherOptions(), acknowledgedModelRisk: false)
        XCTAssertTrue(FlashPreflight.canStart(FlashPreflight.evaluate(input)))

        input.usbMode = .fastboot
        XCTAssertFalse(FlashPreflight.canStart(FlashPreflight.evaluate(input)))
        input.usbMode = .flashMode

        input.deviceModel = nil
        XCTAssertTrue(FlashPreflight.needsModelAcknowledgement(firmware: package, deviceModel: nil))
        XCTAssertFalse(FlashPreflight.canStart(FlashPreflight.evaluate(input)))
        input.acknowledgedModelRisk = true
        XCTAssertTrue(FlashPreflight.canStart(FlashPreflight.evaluate(input)))

        // A non-5V phone can never be acknowledged past.
        input.deviceModel = "XQ-DQ54"
        XCTAssertFalse(FlashPreflight.canStart(FlashPreflight.evaluate(input)))
        XCTAssertFalse(FlashPreflight.needsModelAcknowledgement(firmware: package, deviceModel: "XQ-DQ54"))

        input.deviceModel = "XQ-DE54"
        input.newflasherAvailable = false
        XCTAssertFalse(FlashPreflight.canStart(FlashPreflight.evaluate(input)))
        input.newflasherAvailable = true

        // Slot B is blocked unless explicitly allowed; slot A passes.
        input.currentSlot = "b"
        let slotB = FlashPreflight.evaluate(input)
        XCTAssertFalse(FlashPreflight.canStart(slotB))
        XCTAssertEqual(slotB.first { $0.title == "Active slot" }?.status, .fail)
        input.allowFlashingSlotB = true
        XCTAssertTrue(FlashPreflight.canStart(FlashPreflight.evaluate(input)))
        XCTAssertEqual(FlashPreflight.evaluate(input).first { $0.title == "Active slot" }?.status, .warning)
        input.allowFlashingSlotB = false
        input.currentSlot = "a"
        XCTAssertTrue(FlashPreflight.canStart(FlashPreflight.evaluate(input)))
        input.currentSlot = nil
        XCTAssertEqual(FlashPreflight.evaluate(input).first { $0.title == "Active slot" }?.status, .warning)
        input.usbMode = .notConnected
        XCTAssertNil(FlashPreflight.evaluate(input).first { $0.title == "Active slot" })
    }
}
