import SwiftUI
import XperiaRescueCore

struct FlashView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmFlash = false

    var body: some View {
        Page(
            title: "Flash stock ROM",
            subtitle: "Installs Sony's signed firmware through flash mode with newflasher. Works with a locked or unlocked bootloader."
        ) {
            if let progress = model.flashProgress, model.isFlashing {
                progressCard(progress)
            }

            Card(title: "Checklist", systemImage: "checklist") {
                ForEach(model.preflightChecks, id: \.self) { CheckRow(check: $0) }
                if model.needsModelAcknowledgement {
                    Divider()
                    Toggle(isOn: $model.acknowledgedModelRisk) {
                        Text("I have checked that this firmware is for my phone's model number")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(model.isBusy)
                }
            }

            Card(title: "Options", systemImage: "slider.horizontal.3") {
                Toggle(isOn: $model.options.keepUserData) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep user data (apps, photos, settings)")
                        Text(model.firmware?.supportsKeepingUserData == false
                             ? "Not possible with this firmware: it has no update.xml NOERASE list."
                             : "Try this first. If the phone still bootloops, flash again with it turned off (factory reset).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isBusy || model.firmware?.supportsKeepingUserData == false)

                Toggle(isOn: $model.options.backUpTrimArea) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Back up the trim area (TA) first")
                        Text("A copy is kept in the app's TA Backups folder. DRM keys are not included (newflasher can't read them).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isBusy)

                Picker("After flashing", selection: $model.options.rebootMode) {
                    ForEach(NewflasherRebootMode.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 360)
                .disabled(model.isBusy)

                DisclosureGroup("Advanced") {
                    Toggle("Allow flashing when the battery is below 15 %", isOn: $model.options.allowLowBattery)
                        .disabled(model.isBusy)
                    Text("Not recommended: if the battery dies mid-flash the phone may need another flash to recover.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    model.readPhoneAndBackUpTA()
                } label: {
                    Label("Read Phone & Back Up TA", systemImage: "arrow.down.doc")
                }
                .disabled(model.isBusy || model.usbMode != .flashMode || model.toolPaths[.newflasher] == nil)
                .help("Reads the model number, battery and slot from the phone and saves a TA backup. Nothing is written to the phone.")

                Spacer()

                Button {
                    confirmFlash = true
                } label: {
                    Label("Flash Stock ROM", systemImage: "bolt.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStartFlash)
            }
            .confirmationDialog("Flash \(firmwareName)?", isPresented: $confirmFlash, titleVisibility: .visible) {
                Button(model.willKeepUserData ? "Flash and Keep Data" : "Flash and Erase Phone", role: model.willKeepUserData ? nil : .destructive) {
                    model.startFlash()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }

            if !model.flashModeInfo.isEmpty {
                Card(title: "Phone (from flash mode)", systemImage: "iphone") {
                    if model.isDevelopmentUnit {
                        Callout(style: .info, text: "This phone reports **Default security: OFF** and/or Sony's test signing root: it is a **pre-production (development) unit**. Sony's consumer tools don't support these, and retail firmware may not fully support early prototype hardware.")
                    }
                    KeyValueGrid(rows: deviceRows)
                }
            }

            if let backup = model.lastTABackup {
                HStack {
                    Label("Latest TA backup: \(backup.lastPathComponent)", systemImage: "externaldrive.badge.checkmark")
                    Spacer()
                    Button("Show in Finder") { model.revealInFinder(backup) }
                }
            }

            Card(title: "Trouble?", systemImage: "questionmark.circle") {
                Text("If newflasher can't claim the USB device (LIBUSB_ERROR_ACCESS or BUSY), quit other phone tools, replug the cable, and try again. As a last resort run it in Terminal with administrator rights; you then answer its questions yourself.")
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.openFlashInTerminal()
                } label: {
                    Label("Run in Terminal with sudo…", systemImage: "terminal")
                }
                .disabled(model.isBusy || model.firmware == nil || model.toolPaths[.newflasher] == nil)
            }
        }
    }

    private var firmwareName: String {
        guard let firmware = model.firmware else { return "firmware" }
        return firmware.displayName.isEmpty ? firmware.folder.lastPathComponent : firmware.displayName
    }

    private var confirmMessage: String {
        var lines = [
            model.willKeepUserData
                ? "Apps, photos and settings will be kept."
                : "Everything on the phone will be erased (factory reset).",
            "Flashing takes about 5-15 minutes. Keep the cable connected and don't let the Mac sleep.",
        ]
        if model.options.rebootMode == .android {
            lines.append("The phone reboots automatically when done; the first boot can take several minutes.")
        }
        return lines.joined(separator: "\n\n")
    }

    private var deviceRows: [(String, String)] {
        let keys = ["Product", "Battery level", "Current slot", "Slot count", "Rooting status", "Default security", "Secure", "Bootloader version", "Baseband version", "CDFId", "Serialno"]
        return keys.compactMap { key -> (String, String)? in
            guard let value = model.flashModeInfo[key], !value.isEmpty else { return nil }
            switch key {
            case "Battery level":
                let level = Int(value.prefix { $0.isNumber }) ?? 0
                return (key, level > 0 && !value.contains("unsupported") ? "\(level) %" : "Not reported by this phone: charge it before flashing")
            case "Current slot":
                return (key, "\(value.uppercased()) (slot-specific images are written here)")
            case "Rooting status" where value.uppercased() == "ROOTED":
                return (key, "ROOTED (bootloader unlocked)")
            default:
                return (key, value)
            }
        }
    }

    private func progressCard(_ progress: FlashProgress) -> some View {
        Card(title: "Flashing…", systemImage: "bolt.fill") {
            ProgressView(value: progress.fraction)
            HStack {
                if let file = progress.currentFile {
                    Text("Writing \(file)").lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Connecting and preparing…")
                }
                Spacer()
                if progress.estimatedTotal > 0 {
                    Text("\(progress.processed) of ~\(progress.estimatedTotal)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Callout(style: .warning, text: "**Do not unplug the phone.** The large `super` image takes several minutes on its own.")
        }
    }
}
