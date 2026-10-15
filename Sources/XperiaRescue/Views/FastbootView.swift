import AppKit
import SwiftUI
import XperiaRescueCore

struct FastbootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var partition = "boot"
    @State private var imageURL: URL?
    @State private var slot: FastbootSlotChoice = .current
    @State private var confirmFlashImage = false
    @State private var confirmWipe = false
    @State private var showAllVariables = false

    private let commonPartitions = ["boot", "init_boot", "vendor_boot", "dtbo", "vbmeta", "vbmeta_system", "recovery"]

    var body: some View {
        Page(
            title: "Fastboot tools",
            subtitle: "For the bootloader's fastboot mode (power off, hold Volume Up, plug in USB). A locked bootloader only allows reading information and rebooting."
        ) {
            if model.toolPaths[.fastboot] == nil {
                Callout(style: .warning, text: "fastboot isn't installed yet. Open **Setup & Tools** to download Google's platform-tools.")
                Button("Open Setup & Tools") { model.selection = .setup }
            }

            Card(title: "Bootloader", systemImage: "info.circle") {
                HStack {
                    ModeBadge(mode: model.usbMode)
                    Spacer()
                    Button {
                        Task { await model.readBootloaderInfo() }
                    } label: {
                        Label("Read Bootloader Info", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canRun)
                }
                if let variables = model.fastbootVariables {
                    KeyValueGrid(rows: summaryRows(variables))
                    if variables.isUnlocked == false {
                        Callout(style: .info, text: "The bootloader is **locked**, so fastboot can't flash or erase. That's fine: **Flash Stock ROM** uses flash mode, which works while locked.")
                    }
                    DisclosureGroup("All variables (\(variables.values.count))", isExpanded: $showAllVariables) {
                        KeyValueGrid(rows: variables.values.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }

            Card(title: "Reboot", systemImage: "restart") {
                HStack {
                    Button("Android") { model.fastboot(["reboot"], title: "Rebooting to Android") }
                    Button("Bootloader") { model.fastboot(["reboot", "bootloader"], title: "Rebooting to bootloader") }
                    Button("Recovery") { model.fastboot(["reboot", "recovery"], title: "Rebooting to recovery") }
                    Button("fastbootd") { model.fastboot(["reboot", "fastboot"], title: "Rebooting to fastbootd") }
                }
                .disabled(!canRun)
            }

            Card(title: "Switch active slot", systemImage: "arrow.left.arrow.right") {
                Text("The Xperia 5 V has two copies (slots A and B) of the system. If an update failed, booting the other slot can get past the bootloop. Usually needs an unlocked bootloader.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let current = model.fastbootVariables?.currentSlot {
                        Text("Active slot: \(current.uppercased())").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Make Slot A Active") { model.fastboot(["--set-active=a"], title: "Setting slot A active") }
                    Button("Make Slot B Active") { model.fastboot(["--set-active=b"], title: "Setting slot B active") }
                }
                .disabled(!canRun)
            }

            Card(title: "Flash a single image (unlocked bootloader)", systemImage: "square.and.arrow.down.on.square") {
                Text("For example to put back a stock boot/init_boot image after a failed root. Images come from the stock firmware (convert .sin files with a tool such as UnSIN first).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Partition", text: $partition)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Menu("Common") {
                        ForEach(commonPartitions, id: \.self) { name in
                            Button(name) { partition = name }
                        }
                    }
                    .frame(width: 100)
                    Picker("Slot", selection: $slot) {
                        ForEach(FastbootSlotChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 200)
                }
                HStack {
                    Button("Choose Image…") { chooseImage() }
                    Text(imageURL?.lastPathComponent ?? "No image selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Flash Image") { confirmFlashImage = true }
                        .disabled(!canRun || imageURL == nil || partition.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .confirmationDialog("Flash \(imageURL?.lastPathComponent ?? "") to \(partition)?", isPresented: $confirmFlashImage, titleVisibility: .visible) {
                    Button("Flash", role: .destructive) {
                        if let imageURL {
                            model.flashImage(partition: partition.trimmingCharacters(in: .whitespaces), image: imageURL, slot: slot)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Writing the wrong image to a partition can stop the phone from booting. You can always recover with Flash Stock ROM.")
                }
            }

            Card(title: "Erase user data", systemImage: "trash") {
                Text("`fastboot -w` wipes user data, like a factory reset. Only works on an unlocked bootloader; otherwise flash stock firmware with \"Keep user data\" off.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Erase User Data…", role: .destructive) { confirmWipe = true }
                    .disabled(!canRun)
                    .confirmationDialog("Erase all user data?", isPresented: $confirmWipe, titleVisibility: .visible) {
                        Button("Erase", role: .destructive) { model.fastboot(["-w"], title: "Erasing user data") }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Apps, photos and settings on the phone will be deleted.")
                    }
            }
        }
    }

    private var canRun: Bool {
        !model.isBusy && model.usbMode == .fastboot && model.toolPaths[.fastboot] != nil
    }

    private func summaryRows(_ variables: FastbootVariables) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let product = variables.product { rows.append(("Model", product)) }
        if let unlocked = variables.isUnlocked { rows.append(("Bootloader", unlocked ? "Unlocked" : "Locked")) }
        if let secure = variables["secure"] { rows.append(("Secure boot", secure)) }
        if let slot = variables.currentSlot { rows.append(("Active slot", slot.uppercased())) }
        if let version = variables.bootloaderVersion { rows.append(("Bootloader version", version)) }
        if let baseband = variables.basebandVersion { rows.append(("Baseband", baseband)) }
        if let serial = variables.serialNumber { rows.append(("Serial", serial)) }
        return rows
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an .img file to flash"
        if panel.runModal() == .OK { imageURL = panel.url }
    }
}
