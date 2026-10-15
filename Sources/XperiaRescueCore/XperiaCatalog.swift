import Foundation

/// A regional / carrier variant of the Xperia 5 V.
public struct DeviceVariant: Hashable, Sendable {
    public let model: String
    public let market: String
    public let note: String?

    public init(model: String, market: String, note: String? = nil) {
        self.model = model
        self.market = market
        self.note = note
    }
}

/// Static knowledge about the Xperia 5 V and Sony's USB modes.
public enum XperiaCatalog {
    public static let deviceName = "Xperia 5 V"

    /// Sony's USB vendor ID.
    public static let sonyVendorID = 0x0FCE
    /// Product ID of the S1 "flash mode" loader (Volume Down + plug in).
    /// This is the mode newflasher talks to.
    public static let flashModeProductID = 0xB00B
    /// Product ID of the Sony bootloader in fastboot mode (Volume Up + plug in).
    public static let fastbootProductID = 0x0DDE

    public static let xperia5VVariants: [DeviceVariant] = [
        DeviceVariant(model: "XQ-DE54", market: "Global (Europe, UK, US and others)"),
        DeviceVariant(model: "XQ-DE72", market: "Asia-Pacific (dual SIM)"),
        DeviceVariant(model: "XQ-DE44", market: "Japan (SIM-free)"),
        DeviceVariant(
            model: "SO-53D", market: "Japan (NTT docomo)",
            note: "Carrier model: only flash firmware published for SO-53D."
        ),
        DeviceVariant(
            model: "SOG12", market: "Japan (au / KDDI)",
            note: "Carrier model: only flash firmware published for SOG12."
        ),
    ]

    /// Newest build Sony had published for the Xperia 5 V when this tool was
    /// written. XperiFirm always lists the current one for your region; this
    /// is only used to flag firmware that is clearly older.
    public static let newestKnownFirmware = "67.2.A.3.194"
    public static let newestKnownFirmwareDate = "24 September 2026"

    /// Upper-cases a model string and maps adb's `XQ_DE54` spelling to `XQ-DE54`.
    public static func normalizeModel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    public static func variant(forModel model: String) -> DeviceVariant? {
        let normalized = normalizeModel(model)
        return xperia5VVariants.first { $0.model == normalized }
    }

    public static func isXperia5V(model: String) -> Bool {
        variant(forModel: model) != nil
    }
}
