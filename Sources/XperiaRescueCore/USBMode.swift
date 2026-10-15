import Foundation

/// What the phone is currently doing on the USB bus.
public enum USBConnectionMode: String, Sendable, CaseIterable {
    /// S1 flash mode (0FCE:B00B): stock firmware can be flashed with newflasher,
    /// even with a locked bootloader.
    case flashMode
    /// Bootloader fastboot mode (0FCE:0DDE).
    case fastboot
    /// Any other Sony USB personality: booted Android, recovery, charging, MTP, ADB...
    case android
    case notConnected

    public var title: String {
        switch self {
        case .flashMode: return "Flash mode"
        case .fastboot: return "Fastboot mode"
        case .android: return "Android / recovery"
        case .notConnected: return "Not connected"
        }
    }
}

/// One USB device as reported by the OS.
public struct USBDeviceSnapshot: Hashable, Sendable {
    public let vendorID: Int
    public let productID: Int
    public let productName: String?
    public let serialNumber: String?

    public init(vendorID: Int, productID: Int, productName: String? = nil, serialNumber: String? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.serialNumber = serialNumber
    }

    public var idString: String {
        String(format: "%04X:%04X", vendorID, productID)
    }
}

public enum USBModeClassifier {
    /// Returns nil for devices that are not made by Sony.
    public static func mode(of device: USBDeviceSnapshot) -> USBConnectionMode? {
        guard device.vendorID == XperiaCatalog.sonyVendorID else { return nil }
        switch device.productID {
        case XperiaCatalog.flashModeProductID: return .flashMode
        case XperiaCatalog.fastbootProductID: return .fastboot
        default: return .android
        }
    }

    /// Picks the most useful mode when several Sony devices are attached
    /// (flash mode beats fastboot beats Android).
    public static func bestMode(in devices: [USBDeviceSnapshot]) -> USBConnectionMode {
        let modes = Set(devices.compactMap(mode(of:)))
        for candidate in [USBConnectionMode.flashMode, .fastboot, .android] where modes.contains(candidate) {
            return candidate
        }
        return .notConnected
    }

    /// Sony devices attached, flash-mode ones first.
    public static func sonyDevices(in devices: [USBDeviceSnapshot]) -> [USBDeviceSnapshot] {
        let order: [USBConnectionMode: Int] = [.flashMode: 0, .fastboot: 1, .android: 2]
        return devices
            .filter { mode(of: $0) != nil }
            .sorted { (order[mode(of: $0)!] ?? 9) < (order[mode(of: $1)!] ?? 9) }
    }
}
