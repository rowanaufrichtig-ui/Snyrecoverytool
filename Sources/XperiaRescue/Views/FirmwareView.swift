import SwiftUI
import XperiaRescueCore

struct FirmwareView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        Page(
            title: "Stock firmware",
            subtitle: "Choose the firmware folder for your phone. Sony's firmware is downloaded with XperiFirm, which fetches it directly from Sony's update servers."
        ) {
            chooser
            if let firmware = model.firmware {
                summary(firmware)
                if !firmware.issues.isEmpty {
                    Card(title: "Checks", systemImage: "checklist") {
                        ForEach(firmware.issues, id: \.self) { IssueRow(issue: $0) }
                    }
                }
                files(firmware)
            }
            downloadGuide
        }
    }

    private var chooser: some View {
        HStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.firmware == nil ? "No firmware selected" : "Selected folder")
                    .font(.headline)
                Text(model.firmware?.folder.path ?? "Drop the XperiFirm folder here, or click Choose.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if let firmware = model.firmware {
                Button("Show in Finder") { model.revealInFinder(firmware.folder) }
                Button("Re-check") { model.reinspectFirmware() }
            }
            Button("Choose…") { model.chooseFirmwareFolder() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isFlashing)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isFlashing, let url = urls.first, url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }
            model.loadFirmware(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func summary(_ firmware: FirmwarePackage) -> some View {
        Card(title: "Firmware", systemImage: "shippingbox") {
            KeyValueGrid(rows: [
                ("Model", firmware.model.map { model in
                    XperiaCatalog.variant(forModel: model).map { "\(model) · \($0.market)" } ?? model
                } ?? "Unknown"),
                ("Build", firmware.version ?? "Unknown"),
                ("Region / CDA", [firmware.market, firmware.cda].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Unknown"),
                ("Images", "\(firmware.sinFiles.count) system + \(firmware.bootSinCount) boot (\(firmware.totalBytes.formattedBytes))"),
                ("Keep user data", firmware.supportsKeepingUserData ? "Supported (update.xml)" : "Not supported: flashing erases the phone"),
                ("Your phone", compatibilityText(firmware)),
            ])
        }
    }

    private func compatibilityText(_ firmware: FirmwarePackage) -> String {
        switch firmware.compatibility(withDeviceModel: model.deviceModel) {
        case .match: return "✓ Matches (\(model.deviceModel ?? ""))"
        case .differentVariant(let fw, let device): return "⚠︎ Phone is \(device), firmware is \(fw)"
        case .wrongDevice(let fw, _): return "✗ Wrong device: firmware is for \(fw)"
        case .unknownDevice: return "Not read yet: connect in flash mode and use \"Read Phone & Back Up TA\""
        case .unknownFirmware: return "Firmware model unknown"
        }
    }

    private func files(_ firmware: FirmwarePackage) -> some View {
        Card(title: "Files that will be flashed", systemImage: "doc.on.doc") {
            DisclosureGroup("\(firmware.sinFiles.count) images in the main folder, plus the bootloader set from boot/") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(firmware.sinFiles, id: \.self) { file in
                        GridRow {
                            Text(file.partition).font(.body.weight(.medium))
                            Text(file.size.formattedBytes).foregroundStyle(.secondary).monospacedDigit()
                            Text(note(for: file, firmware: firmware)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func note(for file: FirmwareFile, firmware: FirmwarePackage) -> String {
        if let skip = file.alwaysSkipped { return "Skipped: \(skip.rawValue)" }
        if firmware.noEraseFiles.contains(file.name) { return "Erases user data (skipped when keeping data)" }
        if file.erasesUserData { return "Erases user data" }
        return ""
    }

    private var downloadGuide: some View {
        Card(title: "Download the latest firmware with XperiFirm", systemImage: "arrow.down.circle") {
            StepRow(number: 1, text: "Find your model number: **Settings › About phone**, the label on the SIM tray, or connect the phone in flash mode and click **Read Phone & Back Up TA**. Xperia 5 V models: XQ-DE54, XQ-DE72, XQ-DE44, SO-53D, SOG12.")
            StepRow(number: 2, text: "Get **XperiFirm** from its official XDA thread (not from look-alike download sites). It is a Windows .NET app: on a Mac, run it with Mono, or use any Windows PC or virtual machine (Parallels, VMware Fusion, UTM) and copy the downloaded folder over.")
            HStack {
                Text("With Mono via Homebrew:").foregroundStyle(.secondary)
                CommandText(command: "brew install mono && mono XperiFirm.exe")
            }
            StepRow(number: 3, text: "In XperiFirm open **Xperia 5 V › your model number**, pick your region (any \"Customized\" region for your model is fine for an unbranded phone), select the newest build in the right-hand column and click **Download**. Leave \"Unpack automatically\" on.")
            StepRow(number: 4, text: "When it finishes, choose the folder it created (named like `XQ-DE54_Customized UK_67.2.A.3.194_R3C`) above.")
            Text("Newest build known when this app was made: \(XperiaCatalog.newestKnownFirmware) (\(XperiaCatalog.newestKnownFirmwareDate)). XperiFirm always shows what Sony currently offers.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Link("XperiFirm on XDA", destination: URL(string: "https://xdaforums.com/t/tool-xperifirm-xperia-firmware-downloader-v5-6-1.2834142/")!)
                Link("Mono for macOS", destination: URL(string: "https://www.mono-project.com/download/stable/#download-mac")!)
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
