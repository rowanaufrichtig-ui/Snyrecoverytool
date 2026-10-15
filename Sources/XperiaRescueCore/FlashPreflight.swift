import Foundation

public struct PreflightCheck: Hashable, Sendable {
    public enum Status: Int, Sendable {
        case pass
        case warning
        case fail
    }

    public let title: String
    public let status: Status
    public let detail: String

    public init(_ title: String, _ status: Status, _ detail: String) {
        self.title = title
        self.status = status
        self.detail = detail
    }
}

/// Everything the Flash screen knows when deciding whether flashing may start.
public struct PreflightInput: Sendable {
    public var newflasherAvailable: Bool
    public var firmware: FirmwarePackage?
    public var usbMode: USBConnectionMode
    /// Model number read from the phone (flash-mode probe, fastboot or adb), if known.
    public var deviceModel: String?
    public var options: NewflasherOptions
    /// The user ticked "I understand" for a model warning.
    public var acknowledgedModelRisk: Bool
    /// Active slot reported by the phone ("a"/"b"), if it has been read.
    public var currentSlot: String?
    /// The user chose to flash even though slot B is active.
    public var allowFlashingSlotB: Bool

    public init(newflasherAvailable: Bool, firmware: FirmwarePackage?, usbMode: USBConnectionMode, deviceModel: String?, options: NewflasherOptions, acknowledgedModelRisk: Bool, currentSlot: String? = nil, allowFlashingSlotB: Bool = false) {
        self.newflasherAvailable = newflasherAvailable
        self.firmware = firmware
        self.usbMode = usbMode
        self.deviceModel = deviceModel
        self.options = options
        self.acknowledgedModelRisk = acknowledgedModelRisk
        self.currentSlot = currentSlot
        self.allowFlashingSlotB = allowFlashingSlotB
    }
}

public enum FlashPreflight {
    public static func evaluate(_ input: PreflightInput) -> [PreflightCheck] {
        var checks: [PreflightCheck] = []

        checks.append(input.newflasherAvailable
            ? PreflightCheck("Flasher", .pass, "newflasher is ready.")
            : PreflightCheck("Flasher", .fail, "newflasher was not found. Use a release build of the app (it includes newflasher) or install it under Settings."))

        switch input.usbMode {
        case .flashMode:
            checks.append(PreflightCheck("Phone", .pass, "Connected in flash mode."))
        case .fastboot:
            checks.append(PreflightCheck("Phone", .fail, "The phone is in fastboot mode. Unplug it, power it off, then hold Volume Down while plugging it in to enter flash mode."))
        case .android:
            checks.append(PreflightCheck("Phone", .fail, "The phone is connected but not in flash mode. Power it off (hold Power + Volume Up until it vibrates three times), then hold Volume Down while plugging in USB."))
        case .notConnected:
            checks.append(PreflightCheck("Phone", .fail, "No phone found. Power it off, hold Volume Down and plug in the USB cable."))
        }

        guard let firmware = input.firmware else {
            checks.append(PreflightCheck("Firmware", .fail, "Choose the firmware folder you downloaded with XperiFirm."))
            return checks
        }
        if let error = firmware.issues.first(where: { $0.severity == .error }) {
            checks.append(PreflightCheck("Firmware", .fail, error.message))
        } else {
            let name = firmware.displayName.isEmpty ? firmware.folder.lastPathComponent : firmware.displayName
            checks.append(PreflightCheck("Firmware", .pass, "\(name), \(firmware.sinFiles.count + firmware.bootSinCount) images."))
        }

        checks.append(modelCheck(firmware: firmware, deviceModel: input.deviceModel, acknowledged: input.acknowledgedModelRisk))

        if input.options.keepUserData {
            checks.append(firmware.supportsKeepingUserData
                ? PreflightCheck("User data", .pass, "Kept: apps, photos and settings stay. If the phone still bootloops afterwards, flash again with user data erased.")
                : PreflightCheck("User data", .warning, "This firmware has no update.xml NOERASE list, so newflasher will erase user data anyway."))
        } else {
            checks.append(PreflightCheck("User data", .warning, "Will be erased (factory reset). This is the most reliable bootloop fix."))
        }

        switch input.currentSlot?.lowercased() {
        case "b":
            // newflasher writes slot-specific images to the active slot, but Sony's super
            // image only fills slot A's dynamic partitions (vendor_b, product_b... stay
            // empty), so a phone flashed on slot B restarts at the SONY logo.
            checks.append(input.allowFlashingSlotB
                ? PreflightCheck("Active slot", .warning, "Slot B is active and you chose to flash it anyway. Sony firmware only fills slot A's vendor and product partitions, so slot B usually bootloops at the SONY logo.")
                : PreflightCheck("Active slot", .fail, "Slot B is active. Sony firmware only fills slot A's vendor and product partitions, so a phone flashed on slot B restarts at the SONY logo. Click \"Switch to Slot A\", reconnect in flash mode, then flash."))
        case "a":
            checks.append(PreflightCheck("Active slot", .pass, "Slot A is active."))
        default:
            if input.usbMode == .flashMode {
                checks.append(PreflightCheck("Active slot", .warning, "Not checked yet. Click \"Read Phone & Back Up TA\": if slot B is active, switch to slot A before flashing."))
            }
        }

        if !input.options.backUpTrimArea {
            checks.append(PreflightCheck("TA backup", .warning, "No trim-area backup will be taken. Keeping one is recommended."))
        }
        return checks
    }

    public static func canStart(_ checks: [PreflightCheck]) -> Bool {
        !checks.contains { $0.status == .fail }
    }

    /// Whether the model check is currently waiting for the user's acknowledgement.
    public static func needsModelAcknowledgement(firmware: FirmwarePackage?, deviceModel: String?) -> Bool {
        guard let firmware else { return false }
        switch firmware.compatibility(withDeviceModel: deviceModel) {
        case .match, .wrongDevice: return false
        case .differentVariant, .unknownDevice, .unknownFirmware: return true
        }
    }

    static func modelCheck(firmware: FirmwarePackage, deviceModel: String?, acknowledged: Bool) -> PreflightCheck {
        switch firmware.compatibility(withDeviceModel: deviceModel) {
        case .match:
            return PreflightCheck("Model", .pass, "Firmware and phone are both \(firmware.model ?? "?").")
        case .wrongDevice(let fw, let device):
            let target = device.map { "this phone (\($0))" } ?? "an Xperia 5 V"
            return PreflightCheck("Model", .fail, "Firmware is for \(fw), which is not \(target). Flashing it could brick the phone.")
        case .differentVariant(let fw, let device):
            return acknowledged
                ? PreflightCheck("Model", .warning, "Cross-flashing \(fw) firmware onto a \(device). You accepted the risk.")
                : PreflightCheck("Model", .fail, "Firmware is for \(fw) but the phone is a \(device). Download firmware for \(device), or tick the box to cross-flash anyway (never do this with docomo/au models).")
        case .unknownDevice:
            return acknowledged
                ? PreflightCheck("Model", .warning, "Phone model not verified. You confirmed the firmware (\(firmware.model ?? "?")) matches the label in Settings › About phone or on the SIM tray.")
                : PreflightCheck("Model", .fail, "The phone's model number has not been read yet. Click \"Read phone & back up TA\" first, or tick the box to confirm the firmware matches your phone.")
        case .unknownFirmware:
            return acknowledged
                ? PreflightCheck("Model", .warning, "Firmware model unknown. You confirmed it matches your phone.")
                : PreflightCheck("Model", .fail, "Could not tell which model the firmware is for. Tick the box only if you are sure it is for your phone.")
        }
    }
}
