import Foundation

/// A device line from `adb devices -l`.
public struct ADBDevice: Hashable, Sendable {
    /// `device`, `unauthorized`, `recovery`, `sideload`, `offline`, `bootloader`, ...
    public let serial: String
    public let state: String
    public let attributes: [String: String]

    public init(serial: String, state: String, attributes: [String: String] = [:]) {
        self.serial = serial
        self.state = state
        self.attributes = attributes
    }

    /// `adb devices -l` reports the model with underscores (`XQ_DE54`).
    public var model: String? {
        attributes["model"].map(XperiaCatalog.normalizeModel)
    }

    public var isAuthorized: Bool { state != "unauthorized" && state != "offline" }
}

public enum ADBParser {
    public static func parseDevices(_ output: String) -> [ADBDevice] {
        var devices: [ADBDevice] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") || line.hasPrefix("adb ") {
                continue
            }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }
            var attributes: [String: String] = [:]
            for field in fields.dropFirst(2) {
                guard let colon = field.firstIndex(of: ":") else { continue }
                attributes[String(field[..<colon])] = String(field[field.index(after: colon)...])
            }
            devices.append(ADBDevice(serial: fields[0], state: fields[1], attributes: attributes))
        }
        return devices
    }

    /// Parses `adb shell getprop` output: `[ro.product.model]: [XQ-DE54]`.
    public static func parseGetprop(_ output: String) -> [String: String] {
        var props: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), let separator = trimmed.range(of: "]: [") else { continue }
            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator.lowerBound])
            var value = String(trimmed[separator.upperBound...])
            if value.hasSuffix("]") { value.removeLast() }
            props[key] = value
        }
        return props
    }
}
