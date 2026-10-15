import AppKit
import Foundation
import XperiaRescueCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case start, device, firmware, flash, fastboot, adb, setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: return "Start Here"
        case .device: return "Connect Phone"
        case .firmware: return "Firmware"
        case .flash: return "Flash Stock ROM"
        case .fastboot: return "Fastboot Tools"
        case .adb: return "ADB Tools"
        case .setup: return "Setup & Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .start: return "lifepreserver"
        case .device: return "cable.connector"
        case .firmware: return "shippingbox"
        case .flash: return "bolt.fill"
        case .fastboot: return "terminal"
        case .adb: return "ladybug"
        case .setup: return "wrench.and.screwdriver"
        }
    }
}

struct JobInfo: Equatable {
    let title: String
    let isFlash: Bool
    let startedAt: Date
}

enum JobOutcome: Equatable {
    case success(title: String, detail: String)
    case failure(title: String, detail: String, hints: [String])
}

struct FlashProgress: Equatable {
    var processed: Int
    var estimatedTotal: Int
    var currentFile: String?

    var fraction: Double {
        guard estimatedTotal > 0 else { return 0 }
        return min(Double(processed) / Double(estimatedTotal), 0.99)
    }
}

enum FastbootSlotChoice: String, CaseIterable, Identifiable {
    case current, a, b, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .current: return "Active slot"
        case .a: return "Slot A"
        case .b: return "Slot B"
        case .all: return "Both slots"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem? = .start

    // Tools
    @Published private(set) var toolPaths: [ExternalTool: URL] = [:]
    @Published private(set) var toolVersions: [ExternalTool: String] = [:]
    @Published private(set) var isInstallingPlatformTools = false
    @Published private(set) var platformToolsError: String?

    // USB
    @Published private(set) var usbDevices: [USBDeviceSnapshot] = []
    @Published private(set) var usbMode: USBConnectionMode = .notConnected

    // What we know about the phone
    @Published private(set) var deviceModel: String?
    @Published private(set) var deviceModelSource: String?
    @Published private(set) var flashModeInfo: [String: String] = [:]
    @Published private(set) var fastbootVariables: FastbootVariables?
    @Published private(set) var adbDevices: [ADBDevice] = []
    @Published private(set) var adbProperties: [String: String] = [:]
    @Published private(set) var lastTABackup: URL?
    /// Phone reported "Default security: OFF" / a test signing root in flash mode.
    @Published private(set) var isDevelopmentUnit = false
    /// From flash mode's "Rooting status" (ROOTED = unlocked) or fastboot's "unlocked".
    @Published private(set) var bootloaderUnlocked: Bool?

    // Firmware & flashing
    @Published private(set) var firmware: FirmwarePackage?
    @Published var options = NewflasherOptions()
    @Published var acknowledgedModelRisk = false
    @Published var allowFlashingSlotB = false
    @Published private(set) var flashProgress: FlashProgress?
    @Published var pendingPrompt: NewflasherPrompt?

    // Jobs
    @Published private(set) var activeJob: JobInfo?
    @Published var lastOutcome: JobOutcome?

    let log = LogStore()
    let supportDirectory: URL
    let backupsDirectory: URL

    private var runningCommand: RunningCommand?
    private var usbTimer: Timer?
    private let lastFirmwareKey = "lastFirmwareFolder"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        supportDirectory = base.appendingPathComponent("XperiaRescue", isDirectory: true)
        backupsDirectory = supportDirectory.appendingPathComponent("TA Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        log.appendLine("Xperia Rescue \(Self.appVersion): stock firmware recovery for the \(XperiaCatalog.deviceName).")
        refreshTools()
        if let path = UserDefaults.standard.string(forKey: lastFirmwareKey),
           FileManager.default.fileExists(atPath: path) {
            loadFirmware(URL(fileURLWithPath: path, isDirectory: true), announce: false)
        }
        startUSBMonitoring()
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var isBusy: Bool { activeJob != nil }
    var isFlashing: Bool { activeJob?.isFlash == true }

    var newflasherVersion: String? {
        guard let url = Bundle.main.url(forResource: "newflasher-version", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tools

    func refreshTools() {
        let locator = ToolLocator(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            bundledToolsDirectory: Bundle.main.executableURL?.deletingLastPathComponent(),
            supportDirectory: supportDirectory,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"]
        )
        var paths: [ExternalTool: URL] = [:]
        for tool in ExternalTool.allCases {
            paths[tool] = locator.locate(tool)
        }
        toolPaths = paths
        Task { await refreshToolVersions() }
    }

    private func refreshToolVersions() async {
        var versions: [ExternalTool: String] = [:]
        if let result = await runTool(.adb, ["version"], title: "", quiet: true) {
            versions[.adb] = PlatformTools.parseVersion(result.output)
        }
        if let result = await runTool(.fastboot, ["--version"], title: "", quiet: true) {
            versions[.fastboot] = PlatformTools.parseVersion(result.output)
        }
        if let newflasher = newflasherVersion { versions[.newflasher] = newflasher }
        toolVersions = versions
    }

    func installPlatformTools() {
        guard !isInstallingPlatformTools else { return }
        isInstallingPlatformTools = true
        platformToolsError = nil
        log.appendLine("Downloading Google platform-tools (adb + fastboot) from \(PlatformTools.downloadURL.absoluteString) …")
        Task {
            do {
                try await PlatformToolsInstaller.install(into: supportDirectory)
                log.appendLine("✓ platform-tools installed in \(supportDirectory.appendingPathComponent("platform-tools").path)")
                refreshTools()
            } catch {
                platformToolsError = error.localizedDescription
                log.appendLine("✗ Could not install platform-tools: \(error.localizedDescription)")
            }
            isInstallingPlatformTools = false
        }
    }

    // MARK: - USB

    private func startUSBMonitoring() {
        refreshUSB()
        usbTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUSB() }
        }
    }

    func refreshUSB() {
        let devices = USBModeClassifier.sonyDevices(in: USBScanner.scan())
        if devices != usbDevices { usbDevices = devices }
        let mode = USBModeClassifier.bestMode(in: devices)
        guard mode != usbMode else { return }
        usbMode = mode
        switch mode {
        case .flashMode:
            log.appendLine("● Phone connected in flash mode (0FCE:B00B). Ready to read or flash.")
        case .fastboot:
            log.appendLine("● Phone connected in fastboot mode (0FCE:0DDE).")
            if !isBusy && toolPaths[.fastboot] != nil {
                Task { await readBootloaderInfo() }
            }
        case .android:
            let id = devices.first.map(\.idString) ?? "0FCE"
            log.appendLine("● Sony phone connected (\(id)): Android, recovery or charging mode.")
            if !isBusy && toolPaths[.adb] != nil {
                Task {
                    // Give adbd a moment to come up after enumeration.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !isBusy { await refreshADB() }
                }
            }
        case .notConnected:
            log.appendLine("○ Phone disconnected.")
        }
    }

    private func setDeviceModel(_ raw: String, source: String) {
        let model = FirmwareInspector.extractModel(from: raw) ?? XperiaCatalog.normalizeModel(raw)
        guard !model.isEmpty else { return }
        if deviceModel != model {
            log.appendLine("Phone model: \(model) (read via \(source)).")
        }
        deviceModel = model
        deviceModelSource = source
    }

    func forgetDeviceModel() {
        deviceModel = nil
        deviceModelSource = nil
        flashModeInfo = [:]
        isDevelopmentUnit = false
        bootloaderUnlocked = nil
        acknowledgedModelRisk = false
    }

    // MARK: - Firmware

    func chooseFirmwareFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Firmware"
        panel.message = "Choose the firmware folder that XperiFirm downloaded (it contains *.sin files and a boot folder)."
        if let current = firmware?.folder.deletingLastPathComponent() {
            panel.directoryURL = current
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        if panel.runModal() == .OK, let url = panel.url {
            loadFirmware(url)
        }
    }

    func loadFirmware(_ url: URL, announce: Bool = true) {
        let package = FirmwareInspector.inspect(folder: url, availableBytes: Self.freeSpace(at: url))
        firmware = package
        acknowledgedModelRisk = false
        if !package.supportsKeepingUserData { options.keepUserData = false }
        UserDefaults.standard.set(url.path, forKey: lastFirmwareKey)
        if announce {
            let name = package.displayName.isEmpty ? url.lastPathComponent : package.displayName
            log.appendLine("Firmware selected: \(name) (\(url.path))")
            for issue in package.issues where issue.severity >= .warning {
                log.appendLine("  \(issue.severity == .error ? "✗" : "!") \(issue.message)")
            }
        }
    }

    func reinspectFirmware() {
        guard let folder = firmware?.folder else { return }
        loadFirmware(folder)
    }

    func clearFirmware() {
        firmware = nil
        UserDefaults.standard.removeObject(forKey: lastFirmwareKey)
    }

    nonisolated static func freeSpace(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return nil }
        return Int64(capacity)
    }

    // MARK: - Flash mode (newflasher)

    var preflightChecks: [PreflightCheck] {
        FlashPreflight.evaluate(PreflightInput(
            newflasherAvailable: toolPaths[.newflasher] != nil,
            firmware: firmware,
            usbMode: usbMode,
            deviceModel: deviceModel,
            options: options,
            acknowledgedModelRisk: acknowledgedModelRisk,
            currentSlot: activeSlot,
            allowFlashingSlotB: allowFlashingSlotB
        ))
    }

    /// Active slot ("a"/"b") as last reported in flash mode, or by fastboot.
    var activeSlot: String? {
        if let slot = flashModeInfo["Current slot"]?.lowercased(), slot == "a" || slot == "b" { return slot }
        if let slot = fastbootVariables?.currentSlot?.lowercased(), slot == "a" || slot == "b" { return slot }
        return nil
    }

    /// Sends `set_active:<slot>` to the flash-mode loader (`newflasher set_active:a`).
    /// Unlike fastboot this works with a locked bootloader. Nothing is written except
    /// the slot flags; the phone stays in flash mode and should be reconnected.
    func setActiveSlotInFlashMode(_ slot: String) {
        guard !isBusy, usbMode == .flashMode, slot == "a" || slot == "b",
              let newflasher = toolPaths[.newflasher] else { return }
        let folder = supportDirectory.appendingPathComponent("Commands", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { await runSlotCommand(executable: newflasher, slot: slot, folder: folder) }
    }

    private func runSlotCommand(executable: URL, slot: String, folder: URL) async {
        let title = "Making slot \(slot.uppercased()) active"
        activeJob = JobInfo(title: title, isFlash: false, startedAt: Date())
        lastOutcome = nil
        log.appendLine("")
        log.appendLine("$ cd \(Self.shellQuote(folder.path)) && \(Self.shellQuote(executable.path)) set_active:\(slot)")
        let command = RunningCommand(executable: executable, arguments: ["set_active:\(slot)"], workingDirectory: folder, usePseudoTerminal: true)
        do {
            try command.start()
        } catch {
            activeJob = nil
            lastOutcome = .failure(title: "\(title) could not start", detail: error.localizedDescription, hints: [])
            return
        }
        runningCommand = command
        var analyzer = NewflasherOutputAnalyzer()
        var output = ""
        var status: Int32 = -1
        for await event in command.events {
            switch event {
            case .output(let text):
                log.append(text)
                output += text
                _ = analyzer.feed(text)
            case .exit(let code):
                status = code
            }
        }
        _ = analyzer.finish()
        runningCommand = nil
        activeJob = nil

        if status == 0 && output.contains("Writing command: set_active:") && analyzer.problems.isEmpty {
            flashModeInfo["Current slot"] = slot
            log.appendLine("✓ Slot \(slot.uppercased()) is now active.")
            lastOutcome = .success(
                title: "Slot \(slot.uppercased()) is now active",
                detail: "Unplug the phone and wait about 10 seconds (force it off with Power + Volume Up if the screen lights up), then hold Volume Down and plug it back in to re-enter flash mode. Then flash again: the firmware will be written to slot \(slot.uppercased())."
            )
        } else {
            let hints = Self.uniqueHints(analyzer.problems)
            lastOutcome = .failure(
                title: "Could not switch to slot \(slot.uppercased())",
                detail: "newflasher exited with code \(status).",
                hints: hints.isEmpty ? ["If the phone has an unlocked bootloader, you can also switch slots in Fastboot Tools."] : hints
            )
        }
    }

    var needsModelAcknowledgement: Bool {
        FlashPreflight.needsModelAcknowledgement(firmware: firmware, deviceModel: deviceModel)
    }

    var canStartFlash: Bool { !isBusy && FlashPreflight.canStart(preflightChecks) }

    /// Effective "keep user data": only possible when the package has a NOERASE list.
    var willKeepUserData: Bool { options.keepUserData && (firmware?.supportsKeepingUserData ?? false) }

    func startFlash() {
        guard canStartFlash, let firmware, let newflasher = toolPaths[.newflasher] else { return }
        let flashOptions = NewflasherOptions(
            keepUserData: willKeepUserData,
            rebootMode: options.rebootMode,
            backUpTrimArea: options.backUpTrimArea,
            allowLowBattery: options.allowLowBattery
        )
        let steps = firmware.estimatedFlashSteps
        let name = firmware.displayName.isEmpty ? firmware.folder.lastPathComponent : firmware.displayName
        Task {
            await runNewflasher(
                executable: newflasher, arguments: [], workingDirectory: firmware.folder,
                options: flashOptions, title: "Flashing \(name)",
                isFlash: true, estimatedSteps: steps
            )
        }
    }

    /// Runs `newflasher Dump-trim-area`: reads the phone's details (model, battery,
    /// slot...) and saves a trim-area backup, without flashing anything.
    func readPhoneAndBackUpTA() {
        guard !isBusy, let newflasher = toolPaths[.newflasher] else { return }
        let folder = backupsDirectory.appendingPathComponent("TA \(Self.timestamp())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastOutcome = .failure(title: "Could not create the backup folder", detail: error.localizedDescription, hints: [])
            return
        }
        Task {
            await runNewflasher(
                executable: newflasher, arguments: ["Dump-trim-area"], workingDirectory: folder,
                options: options, title: "Reading phone & backing up TA", isFlash: false, estimatedSteps: 0
            )
        }
    }

    private func runNewflasher(executable: URL, arguments: [String], workingDirectory: URL, options: NewflasherOptions, title: String, isFlash: Bool, estimatedSteps: Int) async {
        activeJob = JobInfo(title: title, isFlash: isFlash, startedAt: Date())
        lastOutcome = nil
        pendingPrompt = nil
        flashProgress = isFlash ? FlashProgress(processed: 0, estimatedTotal: estimatedSteps, currentFile: nil) : nil
        var responder = NewflasherPromptResponder(options: options)
        var analyzer = NewflasherOutputAnalyzer()

        log.appendLine("")
        log.appendLine("$ cd \(Self.shellQuote(workingDirectory.path)) && \(Self.shellQuote(executable.path))\(arguments.map { " " + $0 }.joined())")
        let command = RunningCommand(executable: executable, arguments: arguments, workingDirectory: workingDirectory, usePseudoTerminal: true)
        do {
            try command.start()
        } catch {
            activeJob = nil
            flashProgress = nil
            lastOutcome = .failure(title: "\(title) could not start", detail: error.localizedDescription, hints: [])
            log.appendLine("✗ \(error.localizedDescription)")
            return
        }
        runningCommand = command
        // Keep the Mac awake: sleeping mid-flash would cut the USB transfer.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: title
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        var status: Int32 = -1
        for await event in command.events {
            switch event {
            case .output(let text):
                log.append(text)
                for answer in responder.feed(text) {
                    if let reply = answer.answer {
                        log.appendLine("› \(answer.prompt.summary) → answered \"\(reply)\"")
                        command.send(reply + "\n")
                    } else {
                        pendingPrompt = answer.prompt
                    }
                }
                apply(analyzer.feed(text))
            case .exit(let code):
                status = code
            }
        }
        apply(analyzer.finish())
        runningCommand = nil
        pendingPrompt = nil
        activeJob = nil

        let hints = Self.uniqueHints(analyzer.problems)
        if isFlash {
            finishFlash(status: status, analyzer: analyzer, hints: hints, workingDirectory: workingDirectory, rebootMode: options.rebootMode)
        } else {
            finishProbe(status: status, analyzer: analyzer, hints: hints, folder: workingDirectory)
        }
    }

    private func apply(_ events: [NewflasherEvent]) {
        for event in events {
            switch event {
            case .deviceInfo(let key, let value):
                flashModeInfo[key] = value
                if key == "Product" { setDeviceModel(value, source: "flash mode") }
                if key == "Rooting status" {
                    bootloaderUnlocked = value.uppercased() == "ROOTED"
                }
                if (key == "Default security" && value.uppercased() == "OFF") || (key == "S1 root" && value.contains("_Test")),
                   !isDevelopmentUnit {
                    isDevelopmentUnit = true
                    log.appendLine("ℹ︎ This phone reports \"Default security: OFF\" and/or Sony's test signing root: it is a pre-production (development) unit. Sony's consumer repair tools don't support these, and retail firmware may not fully support early prototype hardware.")
                }
            case .processing(let file):
                if var progress = flashProgress {
                    progress.processed += 1
                    progress.currentFile = file
                    flashProgress = progress
                }
            case .skipped, .trimAreaDumped, .problem, .finished:
                break
            }
        }
    }

    private func finishProbe(status: Int32, analyzer: NewflasherOutputAnalyzer, hints: [String], folder: URL) {
        let taFiles = ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("tadump").path)) ?? [])
            .filter { $0.hasSuffix(".ta") }
        if !taFiles.isEmpty { lastTABackup = folder }
        if status == 0, let model = analyzer.deviceModel {
            var detail = "Phone model \(model)"
            if let battery = analyzer.batteryLevel { detail += ", battery \(battery) %" }
            if let slot = analyzer.currentSlot { detail += ", active slot \(slot.uppercased())" }
            if analyzer.isBootloaderUnlocked == true { detail += ", bootloader unlocked" }
            if analyzer.isDevelopmentUnit { detail += ". This is a pre-production (development) unit" }
            detail += taFiles.isEmpty ? ". No TA backup was written." : ". TA backup saved (\(taFiles.joined(separator: ", ")))."
            lastOutcome = .success(title: "Phone read successfully", detail: detail)
        } else {
            if taFiles.isEmpty { try? FileManager.default.removeItem(at: folder) }
            lastOutcome = .failure(
                title: "Could not read the phone",
                detail: "newflasher exited with code \(status).",
                hints: hints.isEmpty ? ["Make sure the phone is in flash mode, then try again."] : hints
            )
        }
    }

    private func finishFlash(status: Int32, analyzer: NewflasherOutputAnalyzer, hints: [String], workingDirectory: URL, rebootMode: NewflasherRebootMode) {
        flashProgress = nil
        // newflasher writes the TA dump into the firmware folder; keep a copy with the other backups.
        let tadump = workingDirectory.appendingPathComponent("tadump", isDirectory: true)
        if FileManager.default.fileExists(atPath: tadump.path) {
            let copy = backupsDirectory.appendingPathComponent("TA \(Self.timestamp()) (before flash)", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)) != nil,
               (try? FileManager.default.copyItem(at: tadump, to: copy.appendingPathComponent("tadump"))) != nil {
                lastTABackup = copy
            }
        }

        if status == 0 && analyzer.didFinish {
            let next: String
            switch rebootMode {
            case .android: next = "The phone is restarting. The first boot after flashing can take 5-10 minutes; leave it alone until the setup screen or lock screen appears."
            case .powerOff: next = "The phone has been powered off. Unplug it and hold Power to start it; the first boot can take 5-10 minutes."
            default: next = "The phone is rebooting into the mode you chose."
            }
            let slotText = analyzer.currentSlot.map { " to slot \($0.uppercased())" } ?? ""
            let dataText = analyzer.skippedFiles.contains(where: { $0.lowercased().hasPrefix("userdata") })
                ? " User data was kept; if it still bootloops, flash again with \"Keep user data\" turned off."
                : " User data was erased."
            lastOutcome = .success(
                title: "Stock firmware installed",
                detail: "\(analyzer.flashedImages.count) images written\(slotText). \(next)\(dataText)"
            )
            log.appendLine("✓ Flashing finished.")
        } else if status == 0 && hints.isEmpty && !analyzer.flashedImages.isEmpty {
            lastOutcome = .success(title: "newflasher finished", detail: "\(analyzer.flashedImages.count) images written. Check the log to confirm everything was written.")
        } else {
            var allHints = hints
            if analyzer.flashedImages.isEmpty {
                allHints.append("Nothing was written to the phone, so it is no worse off than before.")
            } else {
                allHints.append("Flashing stopped partway. Put the phone back into flash mode and flash again; a complete flash fixes a half-written phone.")
            }
            lastOutcome = .failure(title: "Flashing did not complete", detail: "newflasher exited with code \(status).", hints: allHints)
            log.appendLine("✗ newflasher exited with code \(status).")
        }
    }

    func answerPendingPrompt(_ text: String) {
        guard let command = runningCommand else { pendingPrompt = nil; return }
        log.appendLine("› answered \"\(text)\"")
        command.send(text + "\n")
        pendingPrompt = nil
    }

    func stopActiveJob() {
        guard let command = runningCommand else { return }
        log.appendLine("■ Stopping \(activeJob?.title ?? "command") …")
        command.terminate()
    }

    /// Fallback for USB permission problems: run newflasher with sudo in Terminal,
    /// where the user answers its questions directly.
    func openFlashInTerminal() {
        guard let firmware, let newflasher = toolPaths[.newflasher] else { return }
        let script = """
        #!/bin/bash
        cd \(Self.shellQuote(firmware.folder.path)) || exit 1
        clear
        echo "Xperia Rescue: running newflasher with administrator rights."
        echo "Firmware: \(firmware.folder.lastPathComponent)"
        echo "Answer each question by typing a letter and pressing Return."
        echo "Recommended: keep userdata y (or n for a full wipe), reboot mode a, dump trim area y."
        echo
        sudo \(Self.shellQuote(newflasher.path))
        echo
        read -n 1 -s -r -p "newflasher has finished. Press any key to close this window."
        """
        let url = supportDirectory.appendingPathComponent("Run newflasher.command")
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            log.appendLine("Opened Terminal to run newflasher with sudo (\(url.path)).")
        } catch {
            lastOutcome = .failure(title: "Could not open Terminal", detail: error.localizedDescription, hints: [])
        }
    }

    // MARK: - Fastboot

    func readBootloaderInfo() async {
        guard let devices = await runTool(.fastboot, ["devices"], title: "Looking for fastboot devices") else { return }
        guard !FastbootParser.parseDevices(devices.output).isEmpty else {
            log.appendLine("No device in fastboot mode. Power the phone off, hold Volume Up and plug in USB.")
            return
        }
        guard let result = await runTool(.fastboot, ["getvar", "all"], title: "Reading bootloader info") else { return }
        let variables = FastbootParser.parseVariables(result.output)
        if !variables.values.isEmpty {
            fastbootVariables = variables
            if let product = variables.product { setDeviceModel(product, source: "fastboot") }
            if let unlocked = variables.isUnlocked {
                bootloaderUnlocked = unlocked
                log.appendLine(unlocked
                    ? "Bootloader is UNLOCKED: fastboot flashing is allowed."
                    : "Bootloader is LOCKED: fastboot cannot flash. Use Flash Stock ROM (flash mode), which works while locked.")
            }
        }
    }

    func fastboot(_ arguments: [String], title: String) {
        Task { await runFastbootAction(arguments, title: title) }
    }

    func flashImage(partition: String, image: URL, slot: FastbootSlotChoice) {
        var arguments: [String] = []
        switch slot {
        case .current: break
        case .a, .b, .all: arguments.append("--slot=\(slot.rawValue)")
        }
        arguments += ["flash", partition, image.path]
        fastboot(arguments, title: "Flashing \(image.lastPathComponent) to \(partition)")
    }

    private func runFastbootAction(_ arguments: [String], title: String) async {
        guard usbMode == .fastboot else {
            lastOutcome = .failure(title: "Phone is not in fastboot mode", detail: "Power it off, hold Volume Up and plug in the USB cable.", hints: [])
            return
        }
        guard let result = await runTool(.fastboot, arguments, title: title) else { return }
        if result.succeeded && !result.output.contains("FAILED") {
            lastOutcome = .success(title: title, detail: "fastboot reported success.")
        } else {
            let hint = FastbootParser.explainFailure(result.output)
            lastOutcome = .failure(title: "\(title) failed", detail: "fastboot exited with code \(result.status).", hints: hint.map { [$0] } ?? [])
        }
    }

    // MARK: - ADB

    func refreshADB() async {
        guard let result = await runTool(.adb, ["devices", "-l"], title: "Looking for adb devices") else { return }
        adbDevices = ADBParser.parseDevices(result.output)
        if adbDevices.contains(where: { $0.state == "unauthorized" }) {
            log.appendLine("The phone has not authorised this Mac yet: unlock it and tap \"Allow\" on the USB debugging prompt.")
        }
        guard let device = adbDevices.first(where: { $0.state == "device" || $0.state == "recovery" }) else {
            if adbDevices.isEmpty {
                log.appendLine("No adb device. adb only works if Android boots far enough with USB debugging enabled.")
            }
            return
        }
        if let props = await runTool(.adb, ["-s", device.serial, "shell", "getprop"], title: "Reading phone properties", echo: false) {
            let parsed = ADBParser.parseGetprop(props.output)
            if !parsed.isEmpty { adbProperties = parsed }
            if let model = parsed["ro.product.model"] ?? device.model { setDeviceModel(model, source: "adb") }
        }
    }

    var primaryADBSerial: String? {
        adbDevices.first(where: { $0.state == "device" || $0.state == "recovery" || $0.state == "sideload" })?.serial
    }

    func adbReboot(_ target: String?) {
        guard let serial = primaryADBSerial else { return }
        let arguments = ["-s", serial, "reboot"] + (target.map { [$0] } ?? [])
        let title = target.map { "Rebooting phone to \($0)" } ?? "Rebooting phone"
        Task {
            if let result = await runTool(.adb, arguments, title: title), !result.succeeded {
                lastOutcome = .failure(title: "adb reboot failed", detail: result.output, hints: [])
            }
        }
    }

    func saveLogcat() {
        guard let serial = primaryADBSerial else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xperia-logcat-\(Self.timestamp()).txt"
        panel.message = "Save the phone's log (useful to find what causes the bootloop)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let result = await runTool(.adb, ["-s", serial, "logcat", "-d", "-b", "all"], title: "Saving logcat", echo: false) else { return }
            do {
                try result.output.write(to: url, atomically: true, encoding: .utf8)
                lastOutcome = .success(title: "Log saved", detail: url.path)
                log.appendLine("Saved \(result.output.count) characters of logcat to \(url.path)")
            } catch {
                lastOutcome = .failure(title: "Could not save the log", detail: error.localizedDescription, hints: [])
            }
        }
    }

    // MARK: - Running tools

    /// Runs adb / fastboot to completion. `quiet` runs are background checks:
    /// they don't block the UI or write to the log.
    @discardableResult
    func runTool(_ tool: ExternalTool, _ arguments: [String], title: String, echo: Bool = true, quiet: Bool = false) async -> CommandResult? {
        guard let executable = toolPaths[tool] else {
            if !quiet {
                log.appendLine("✗ \(tool.title) is not installed. Open Setup & Tools to install it.")
                lastOutcome = .failure(title: "\(tool.title) is not installed", detail: "Open Setup & Tools and download Google's platform-tools.", hints: [])
            }
            return nil
        }
        if !quiet {
            guard activeJob == nil else { return nil }
            activeJob = JobInfo(title: title, isFlash: false, startedAt: Date())
            log.appendLine("$ \(tool.rawValue) \(arguments.map(Self.shellQuoteIfNeeded).joined(separator: " "))")
        }
        let command = RunningCommand(executable: executable, arguments: arguments)
        do {
            try command.start()
        } catch {
            if !quiet {
                activeJob = nil
                log.appendLine("✗ \(error.localizedDescription)")
            }
            return nil
        }
        if !quiet { runningCommand = command }

        var output = ""
        var status: Int32 = -1
        for await event in command.events {
            switch event {
            case .output(let text):
                output += text
                if echo && !quiet { log.append(text) }
            case .exit(let code):
                status = code
            }
        }
        if !quiet {
            runningCommand = nil
            activeJob = nil
            if status != 0 { log.appendLine("(exit code \(status))") }
        }
        return CommandResult(status: status, output: output)
    }

    // MARK: - Helpers

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    nonisolated static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    nonisolated static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func shellQuoteIfNeeded(_ text: String) -> String {
        text.rangeOfCharacter(from: CharacterSet(charactersIn: " '\"$&;|<>()*?")) == nil ? text : shellQuote(text)
    }

    private static func uniqueHints(_ problems: [NewflasherProblem]) -> [String] {
        var seen = Set<String>()
        return problems.map(\.hint).filter { seen.insert($0).inserted }
    }
}
