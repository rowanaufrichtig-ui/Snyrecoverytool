import Foundation

public struct FastbootDevice: Hashable, Sendable {
    public let serial: String
    public let state: String

    public init(serial: String, state: String) {
        self.serial = serial
        self.state = state
    }
}

/// Bootloader variables reported by `fastboot getvar all` (or single getvars).
public struct FastbootVariables: Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> String? { values[key] }

    public var product: String? { values["product"].map(XperiaCatalog.normalizeModel) }
    public var serialNumber: String? { values["serialno"] }
    public var currentSlot: String? { values["current-slot"] }
    public var bootloaderVersion: String? { values["version-bootloader"] }
    public var basebandVersion: String? { values["version-baseband"] }

    /// nil when the bootloader did not report it.
    public var isUnlocked: Bool? {
        guard let raw = values["unlocked"]?.lowercased() else { return nil }
        if ["yes", "true", "1"].contains(raw) { return true }
        if ["no", "false", "0"].contains(raw) { return false }
        return nil
    }
}

public enum FastbootParser {
    /// Parses `fastboot devices` / `fastboot devices -l`.
    public static func parseDevices(_ output: String) -> [FastbootDevice] {
        output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2, fields[1] == "fastboot" || fields[1] == "fastbootd" else { return nil }
            return FastbootDevice(serial: fields[0], state: fields[1])
        }
    }

    /// Parses `fastboot getvar all` and `fastboot getvar <name>` output.
    ///
    /// `getvar all` lines look like `(bootloader) product:XQ-DE54` or
    /// `(bootloader) partition-size:boot_a: 0x6000000`; a single getvar
    /// prints `product: XQ-DE54`.
    public static func parseVariables(_ output: String) -> FastbootVariables {
        var values: [String: String] = [:]
        for rawLine in output.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBootloaderLine = line.hasPrefix("(bootloader)")
            if isBootloaderLine {
                line = line.dropFirst("(bootloader)".count).trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty || line.hasPrefix("Finished.") || line.hasPrefix("all:") || line.hasPrefix("<") {
                continue
            }
            if !isBootloaderLine && (line.hasPrefix("FAILED") || line.hasPrefix("fastboot:") || line.hasPrefix("getvar:")) {
                continue
            }
            // Prefer the last ": " so that `partition-size:boot_a: 0x...` keys keep their partition.
            let key: String
            let value: String
            if let separator = line.range(of: ": ", options: .backwards) {
                key = String(line[..<separator.lowerBound])
                value = String(line[separator.upperBound...])
            } else if let colon = line.firstIndex(of: ":") {
                key = String(line[..<colon])
                value = String(line[line.index(after: colon)...])
            } else {
                continue
            }
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            guard !trimmedKey.isEmpty, !trimmedKey.contains(" ") else { continue }
            values[trimmedKey] = value.trimmingCharacters(in: .whitespaces)
        }
        return FastbootVariables(values: values)
    }

    /// Common reasons fastboot commands fail on a Sony device, in plain words.
    public static func explainFailure(_ output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("command not allowed") || lower.contains("not allowed in locked state")
            || lower.contains("flashing is not allowed") {
            return "The bootloader is locked, so it refuses fastboot flash/erase commands. Use Flash Stock ROM (flash mode) instead: it works with a locked bootloader."
        }
        if lower.contains("no such file or directory") {
            return "fastboot could not read the image file. Check the file still exists."
        }
        if lower.contains("partition does not exist") || lower.contains("partition table doesn't exist") || lower.contains("no such partition") {
            return "That partition does not exist on this device. Check the partition name (Xperia 5 V uses A/B slots, e.g. boot_a / boot_b)."
        }
        if lower.contains("< waiting for") {
            return "fastboot is waiting for a device. Put the phone in fastboot mode (power off, hold Volume Up, plug in USB)."
        }
        return nil
    }
}
