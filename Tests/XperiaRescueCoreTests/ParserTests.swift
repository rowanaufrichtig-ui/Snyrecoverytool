import XCTest
@testable import XperiaRescueCore

final class ParserTests: XCTestCase {
    func testADBDevicesListParsesStateAndModel() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        QV7123ABCD             device usb:1-1 product:pdx237 model:XQ_DE54 device:pdx237 transport_id:3
        QV7999ZZZZ             unauthorized usb:1-2 transport_id:4

        """
        let devices = ADBParser.parseDevices(output)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].serial, "QV7123ABCD")
        XCTAssertEqual(devices[0].state, "device")
        XCTAssertEqual(devices[0].model, "XQ-DE54")
        XCTAssertEqual(devices[0].attributes["device"], "pdx237")
        XCTAssertTrue(devices[0].isAuthorized)
        XCTAssertEqual(devices[1].state, "unauthorized")
        XCTAssertFalse(devices[1].isAuthorized)
        XCTAssertNil(devices[1].model)
    }

    func testADBDevicesEmpty() {
        XCTAssertTrue(ADBParser.parseDevices("List of devices attached\n\n").isEmpty)
    }

    func testGetprop() {
        let output = """
        [ro.build.display.id]: [67.2.A.3.194]
        [ro.product.model]: [XQ-DE54]
        [ro.boot.slot_suffix]: [_a]
        garbage line
        """
        let props = ADBParser.parseGetprop(output)
        XCTAssertEqual(props["ro.product.model"], "XQ-DE54")
        XCTAssertEqual(props["ro.build.display.id"], "67.2.A.3.194")
        XCTAssertEqual(props["ro.boot.slot_suffix"], "_a")
        XCTAssertEqual(props.count, 3)
    }

    func testFastbootDevices() {
        let output = "QV7123ABCD\tfastboot\nQV7000\tfastbootd\n\n"
        let devices = FastbootParser.parseDevices(output)
        XCTAssertEqual(devices, [FastbootDevice(serial: "QV7123ABCD", state: "fastboot"), FastbootDevice(serial: "QV7000", state: "fastbootd")])
    }

    func testFastbootGetvarAll() {
        let output = """
        (bootloader) version-bootloader:1325-7771_X_Boot_SDM8550_LA2.0_U_XXX
        (bootloader) version-baseband:1325-3029_67.2.A.3.194
        (bootloader) product:XQ-DE54
        (bootloader) secure:yes
        (bootloader) unlocked:no
        (bootloader) current-slot:a
        (bootloader) partition-size:boot_a: 0x6000000
        (bootloader) serialno:QV7123ABCD
        all:
        Finished. Total time: 0.050s
        """
        let vars = FastbootParser.parseVariables(output)
        XCTAssertEqual(vars.product, "XQ-DE54")
        XCTAssertEqual(vars.isUnlocked, false)
        XCTAssertEqual(vars.currentSlot, "a")
        XCTAssertEqual(vars.serialNumber, "QV7123ABCD")
        XCTAssertEqual(vars["partition-size:boot_a"], "0x6000000")
        XCTAssertEqual(vars.bootloaderVersion, "1325-7771_X_Boot_SDM8550_LA2.0_U_XXX")
        XCTAssertNil(vars["all"])
    }

    func testFastbootSingleGetvar() {
        let vars = FastbootParser.parseVariables("product: XQ-DE72\nFinished. Total time: 0.001s\n")
        XCTAssertEqual(vars.product, "XQ-DE72")
        XCTAssertEqual(vars.values.count, 1)
    }

    func testFastbootFailureExplanation() {
        XCTAssertNotNil(FastbootParser.explainFailure("FAILED (remote: 'Command not allowed')"))
        XCTAssertNotNil(FastbootParser.explainFailure("FAILED (remote: 'Flashing is not allowed in Lock State')"))
        XCTAssertNil(FastbootParser.explainFailure("OKAY [  0.010s]"))
    }

    func testUSBModeClassification() {
        let flash = USBDeviceSnapshot(vendorID: 0x0FCE, productID: 0xB00B)
        let fastboot = USBDeviceSnapshot(vendorID: 0x0FCE, productID: 0x0DDE)
        let android = USBDeviceSnapshot(vendorID: 0x0FCE, productID: 0x01F4)
        let other = USBDeviceSnapshot(vendorID: 0x05AC, productID: 0x1234)
        XCTAssertEqual(USBModeClassifier.mode(of: flash), .flashMode)
        XCTAssertEqual(USBModeClassifier.mode(of: fastboot), .fastboot)
        XCTAssertEqual(USBModeClassifier.mode(of: android), .android)
        XCTAssertNil(USBModeClassifier.mode(of: other))
        XCTAssertEqual(USBModeClassifier.bestMode(in: [other, android, flash]), .flashMode)
        XCTAssertEqual(USBModeClassifier.bestMode(in: [other]), .notConnected)
        XCTAssertEqual(USBModeClassifier.sonyDevices(in: [android, other, fastboot]), [fastboot, android])
        XCTAssertEqual(flash.idString, "0FCE:B00B")
    }

    func testCatalogNormalization() {
        XCTAssertEqual(XperiaCatalog.normalizeModel(" xq_de54 "), "XQ-DE54")
        XCTAssertTrue(XperiaCatalog.isXperia5V(model: "XQ_DE72"))
        XCTAssertTrue(XperiaCatalog.isXperia5V(model: "SOG12"))
        XCTAssertFalse(XperiaCatalog.isXperia5V(model: "XQ-DQ54"))
    }

    func testToolLocatorOrder() {
        let home = URL(fileURLWithPath: "/Users/me")
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support/XperiaRescue")
        let bundle = URL(fileURLWithPath: "/Applications/Xperia Rescue.app/Contents/MacOS")
        let existing: Set<String> = [
            "/opt/homebrew/bin/adb",
            "/Users/me/Library/Application Support/XperiaRescue/platform-tools/adb",
            "/Applications/Xperia Rescue.app/Contents/MacOS/newflasher",
            "/usr/local/bin/fastboot",
        ]
        let locator = ToolLocator(
            homeDirectory: home, bundledToolsDirectory: bundle, supportDirectory: support,
            pathEnvironment: "/usr/bin:/opt/homebrew/bin", isExecutable: { existing.contains($0) }
        )
        XCTAssertEqual(locator.locate(.adb)?.path, "/Users/me/Library/Application Support/XperiaRescue/platform-tools/adb")
        XCTAssertEqual(locator.locate(.fastboot)?.path, "/usr/local/bin/fastboot")
        XCTAssertEqual(locator.locate(.newflasher)?.path, "/Applications/Xperia Rescue.app/Contents/MacOS/newflasher")
        // Duplicate PATH entries are removed.
        let paths = locator.candidates(for: .adb).map(\.path)
        XCTAssertEqual(paths.count, Set(paths).count)
    }

    func testPlatformToolsVersion() {
        XCTAssertEqual(PlatformTools.parseVersion("Android Debug Bridge version 1.0.41\nVersion 36.0.0-13206524\nInstalled as /x/adb\n"), "36.0.0-13206524")
        XCTAssertEqual(PlatformTools.parseVersion("fastboot version 36.0.0-13206524\nInstalled as /x/fastboot\n"), "36.0.0-13206524")
        XCTAssertNil(PlatformTools.parseVersion("nonsense"))
    }
}
