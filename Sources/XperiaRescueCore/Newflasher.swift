import Foundation

/// What newflasher should do with the phone after flashing.
public enum NewflasherRebootMode: String, CaseIterable, Identifiable, Sendable {
    case android = "a"
    case fastboot = "f"
    case fastbootd = "d"
    case recovery = "r"
    case sameMode = "s"
    case powerOff = "p"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .android: return "Boot Android"
        case .fastboot: return "Reboot to fastboot"
        case .fastbootd: return "Reboot to fastbootd"
        case .recovery: return "Reboot to recovery"
        case .sameMode: return "Stay in flash mode"
        case .powerOff: return "Power off"
        }
    }
}

public struct NewflasherOptions: Equatable, Sendable {
    /// Skip the files listed as NOERASE in update.xml so apps, photos and settings survive.
    public var keepUserData: Bool
    public var rebootMode: NewflasherRebootMode
    /// Save a trim-area (TA) backup before flashing.
    public var backUpTrimArea: Bool
    /// Continue even if newflasher reports less than 15 % battery.
    public var allowLowBattery: Bool

    public init(keepUserData: Bool = true, rebootMode: NewflasherRebootMode = .android, backUpTrimArea: Bool = true, allowLowBattery: Bool = false) {
        self.keepUserData = keepUserData
        self.rebootMode = rebootMode
        self.backUpTrimArea = backUpTrimArea
        self.allowLowBattery = allowLowBattery
    }
}

/// A question newflasher asked on stdin.
public enum NewflasherPrompt: Equatable, Sendable {
    case gordonGateDriver
    case keepUserData
    case rebootMode
    case dumpTrimArea
    case lowBattery(level: Int?)
    /// A prompt this app does not recognise (newer newflasher?). The user has to answer it.
    case unknown(String)

    public var summary: String {
        switch self {
        case .gordonGateDriver: return "Extract Windows driver?"
        case .keepUserData: return "Keep user data?"
        case .rebootMode: return "What to do after flashing?"
        case .dumpTrimArea: return "Back up the trim area (TA)?"
        case .lowBattery(let level): return "Battery is low (\(level.map { "\($0) %" } ?? "under 15 %")). Continue?"
        case .unknown(let text): return text
        }
    }
}

public struct NewflasherPromptAnswer: Equatable, Sendable {
    public let prompt: NewflasherPrompt
    /// nil means the app cannot answer and must ask the user.
    public let answer: String?

    public init(prompt: NewflasherPrompt, answer: String?) {
        self.prompt = prompt
        self.answer = answer
    }
}

/// Watches newflasher's output and answers its interactive questions from `NewflasherOptions`.
///
/// newflasher asks its questions with `scanf(" %c")`, and whether a question
/// appears depends on the firmware (update.xml) and the phone (battery level),
/// so answers cannot simply be piped in up front. Each prompt is a complete line
/// containing "press ENTER", so the responder works on whole lines.
public struct NewflasherPromptResponder {
    public var options: NewflasherOptions
    private var partialLine = ""
    private var lastBatteryLevel: Int?

    public init(options: NewflasherOptions) {
        self.options = options
    }

    public mutating func feed(_ text: String) -> [NewflasherPromptAnswer] {
        var answers: [NewflasherPromptAnswer] = []
        partialLine += text
        while let newline = partialLine.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = String(partialLine[..<newline])
            partialLine.removeSubrange(...newline)
            if let answer = handle(line: line) {
                answers.append(answer)
            }
        }
        return answers
    }

    private mutating func handle(line: String) -> NewflasherPromptAnswer? {
        let lower = line.lowercased()
        if let level = Self.batteryLevel(inWarning: line) {
            lastBatteryLevel = level
        }
        guard lower.contains("press enter") else { return nil }

        if lower.contains("gordongate") {
            return NewflasherPromptAnswer(prompt: .gordonGateDriver, answer: "n")
        }
        if lower.contains("keep userdata") {
            return NewflasherPromptAnswer(prompt: .keepUserData, answer: options.keepUserData ? "y" : "n")
        }
        if lower.contains("for reboot to android") {
            return NewflasherPromptAnswer(prompt: .rebootMode, answer: options.rebootMode.rawValue)
        }
        if lower.contains("dump trim area") {
            return NewflasherPromptAnswer(prompt: .dumpTrimArea, answer: options.backUpTrimArea ? "y" : "n")
        }
        if lower.contains("understand the risk") {
            return NewflasherPromptAnswer(prompt: .lowBattery(level: lastBatteryLevel), answer: options.allowLowBattery ? "y" : "n")
        }
        return NewflasherPromptAnswer(prompt: .unknown(line.trimmingCharacters(in: .whitespaces)), answer: nil)
    }

    static func batteryLevel(inWarning line: String) -> Int? {
        guard let range = line.range(of: "Your battery level is ") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}

/// Things worth showing the user while newflasher runs.
public enum NewflasherEvent: Equatable, Sendable {
    case deviceInfo(key: String, value: String)
    case processing(file: String)
    case skipped(file: String)
    case trimAreaDumped
    case problem(NewflasherProblem)
    case finished
}

public struct NewflasherProblem: Equatable, Sendable {
    public let line: String
    public let hint: String

    public init(line: String, hint: String) {
        self.line = line
        self.hint = hint
    }
}

/// Turns newflasher's console output into structured events.
public struct NewflasherOutputAnalyzer {
    /// Keys of the "Key: value" device report newflasher prints after connecting.
    public static let deviceInfoKeys: Set<String> = [
        "Product", "Version", "Bootloader version", "Baseband version", "Serialno", "Secure",
        "Loader version", "Phone ID", "Device ID", "Platform ID", "Rooting status",
        "Ufs info", "Emmc info", "Security state", "Slot count", "Current slot",
        "Battery level", "CDFId", "SPC", "Keystore counter", "Default security",
        "S1 root", "Sake root", "Root key hash",
    ]

    private var partialLine = ""
    public private(set) var deviceInfo: [String: String] = [:]
    public private(set) var processedFiles: [String] = []
    public private(set) var skippedFiles: [String] = []
    public private(set) var problems: [NewflasherProblem] = []
    public private(set) var didFinish = false

    public init() {}

    /// The phone's model number as reported in flash mode, e.g. XQ-DE54.
    public var deviceModel: String? {
        deviceInfo["Product"].flatMap { value in
            FirmwareInspector.extractModel(from: value) ?? (value.isEmpty ? nil : XperiaCatalog.normalizeModel(value))
        }
    }

    /// nil when the loader can't report it (newflasher then prints "0 unsupported command").
    public var batteryLevel: Int? {
        guard let raw = deviceInfo["Battery level"], !raw.contains("unsupported"),
              let level = Int(raw.prefix { $0.isNumber }), level > 0 else { return nil }
        return level
    }

    /// The slot newflasher writes slot-specific images to (and leaves active): "a" or "b".
    public var currentSlot: String? {
        guard let slot = deviceInfo["Current slot"]?.lowercased(), slot == "a" || slot == "b" else { return nil }
        return slot
    }

    /// Pre-production phones report "Default security: OFF" and carry Sony's test signing root.
    public var isDevelopmentUnit: Bool {
        deviceInfo["Default security"]?.uppercased() == "OFF" || (deviceInfo["S1 root"]?.contains("_Test") ?? false)
    }

    /// Sony's loader reports an unlocked bootloader as "Rooting status: ROOTED".
    public var isBootloaderUnlocked: Bool? {
        guard let status = deviceInfo["Rooting status"]?.uppercased(), !status.isEmpty else { return nil }
        return status == "ROOTED"
    }

    /// Images actually written: processed .sin files that newflasher did not then skip.
    public var flashedImages: [String] {
        let skipped = Set(skippedFiles)
        return processedFiles.filter { !skipped.contains($0) }
    }

    public mutating func feed(_ text: String) -> [NewflasherEvent] {
        var events: [NewflasherEvent] = []
        partialLine += text
        while let newline = partialLine.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            // Progress output uses \r: only the last segment of a line matters.
            let rawLine = String(partialLine[..<newline])
            partialLine.removeSubrange(...newline)
            let line = rawLine.components(separatedBy: "\r").last ?? rawLine
            events.append(contentsOf: handle(line: line))
        }
        return events
    }

    /// Call when the process has exited to flush a final unterminated line.
    public mutating func finish() -> [NewflasherEvent] {
        guard !partialLine.isEmpty else { return [] }
        let line = partialLine
        partialLine = ""
        return handle(line: line)
    }

    private mutating func handle(line rawLine: String) -> [NewflasherEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }
        var events: [NewflasherEvent] = []

        if let colon = line.range(of: ": ") {
            let key = String(line[..<colon.lowerBound])
            if Self.deviceInfoKeys.contains(key) {
                let value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                deviceInfo[key] = value
                events.append(.deviceInfo(key: key, value: value))
            }
        }
        if line.hasPrefix("Processing ") {
            // Only image files count; "Processing .sin files..." and .ta writes are not images.
            let path = String(line.dropFirst("Processing ".count))
            let file = path.split(separator: "/").last.map(String.init) ?? path
            if file.lowercased().hasSuffix(".sin") {
                processedFiles.append(file)
                events.append(.processing(file: file))
            }
        } else if let file = Self.skippedFile(in: line) {
            skippedFiles.append(file)
            events.append(.skipped(file: file))
        }
        if line.hasPrefix("Dumping trim area to tadump folder") {
            events.append(.trimAreaDumped)
        }
        if line == "Done." || line.hasPrefix("End. You can disconnect") {
            didFinish = true
            events.append(.finished)
        }
        if let problem = Self.problem(for: line) {
            problems.append(problem)
            events.append(.problem(problem))
        }
        return events
    }

    static func skippedFile(in line: String) -> String? {
        for prefix in ["- Skipping ", "Skipping "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    /// Maps newflasher's error lines to advice. Public so the UI can explain raw log lines too.
    public static func problem(for line: String) -> NewflasherProblem? {
        let lower = line.lowercased()
        func make(_ hint: String) -> NewflasherProblem { NewflasherProblem(line: line, hint: hint) }

        if lower.contains("no usb device with vid") {
            return make("The phone is not in flash mode. Unplug it, power it off completely, then hold Volume Down while plugging the USB cable back in.")
        }
        if lower.contains("you do not have needed") && lower.contains("free space") {
            return make("Not enough disk space. newflasher needs 10 GB free on the disk that holds the firmware folder.")
        }
        if lower.contains("libusb init error") {
            return make("libusb could not start. Reinstall the app, or install libusb with Homebrew (brew install libusb).")
        }
        if lower.contains("libusb_error_access") || lower.contains("libusb_error_busy") {
            return make("macOS would not hand the USB device over. Quit other phone tools (Android File Transfer, OpenMTP, Android Studio, other flashers), replug the cable, and try again. If it keeps failing, use \"Run in Terminal with sudo\".")
        }
        if lower.contains("libusb_error_no_device") || lower.contains("libusb_error_io") || lower.contains("libusb_error_pipe")
            || lower.contains("libusb_error_timeout") || lower.contains("libusb_error_overflow") {
            return make("The USB connection dropped. Use a good USB-C cable plugged directly into the Mac (no hub or dock), then restart from flash mode.")
        }
        if lower.contains("didn't found bootdelivery") || lower.contains("didn't find bootdelivery") {
            return make("The bootloader package in this firmware does not match this phone. Make sure you downloaded firmware for your exact model number.")
        }
        if lower.contains("error parsing") || lower.contains("invalid or incomplete deflate data") || lower.contains("error reading") {
            return make("A firmware file looks damaged. Download the firmware again with XperiFirm.")
        }
        if lower.contains("hard brick") && lower.contains("battery") {
            return make("The battery is low. Charge the phone (at least 15 %, ideally 50 %) before flashing.")
        }
        if lower.hasPrefix("error") || lower.hasPrefix("- error") || lower.hasPrefix(" - error") || lower.contains(" fail with error") || lower.contains("failed with error") {
            return make("newflasher reported an error. Check the log above; if flashing stopped midway, put the phone back in flash mode and start again: nothing is lost by reflashing.")
        }
        return nil
    }
}
