import SwiftUI
import XperiaRescueCore

struct StartView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Page(
            title: "Rescue a bootlooping Xperia 5 V",
            subtitle: "Reinstall Sony's official stock Android firmware from your Mac, even when the phone can't boot and Sony's own tools won't work."
        ) {
            Callout(style: .info, text: "**How it works:** Sony doesn't publish fastboot images, and a locked bootloader rejects `fastboot flash`. Instead this app uses the phone's **flash mode**, a fastboot-style USB mode built into every Xperia, through the open-source **newflasher**. It installs Sony's signed firmware whether the bootloader is locked or unlocked. Fastboot and ADB tools are in the sidebar for diagnosis and extra repairs.")

            Card(title: "Steps", systemImage: "list.number") {
                step(1, "Get the tools", done: model.toolPaths[.newflasher] != nil,
                     detail: model.toolPaths[.newflasher] != nil ? "newflasher is ready. adb and fastboot are optional." : "newflasher is missing; see Setup & Tools.",
                     target: .setup)
                step(2, "Download the latest stock firmware", done: model.firmware.map { !$0.hasErrors } ?? false,
                     detail: model.firmware.map { $0.displayName.isEmpty ? $0.folder.lastPathComponent : $0.displayName } ?? "Use XperiFirm to download the firmware for your model, then choose its folder.",
                     target: .firmware)
                step(3, "Put the phone in flash mode", done: model.usbMode == .flashMode,
                     detail: model.usbMode == .flashMode ? "Connected in flash mode." : "Power off, hold Volume Down, plug in the USB cable.",
                     target: .device)
                step(4, "Read the phone and back up its TA", done: model.deviceModel != nil,
                     detail: model.deviceModel.map { "Model \($0) confirmed." } ?? "Confirms the model number and saves a trim-area backup. Recommended.",
                     target: .flash)
                step(5, "Flash the stock ROM", done: false,
                     detail: "Keep your data first; if the phone still loops, flash again with data erased.",
                     target: .flash)
            }

            Card(title: "Before you start", systemImage: "checklist") {
                Label("Charge the phone for at least 30 minutes if you can. Flashing with a nearly flat battery is risky.", systemImage: "battery.75")
                Label("Use a good USB-C cable plugged straight into the Mac, not through a hub or dock.", systemImage: "cable.connector")
                Label("You need about 10 GB free disk space next to the firmware folder.", systemImage: "internaldrive")
                Label("If the phone still reaches Android with USB debugging on, save anything important first (ADB Tools can save a log of the bootloop).", systemImage: "externaldrive.badge.checkmark")
            }

            Callout(style: .warning, text: "Use firmware for **your exact model number** (Settings › About phone, the SIM tray, or what this app reads from the phone). The Japanese carrier models **SO-53D** (docomo) and **SOG12** (au) must only get their own firmware.")
        }
    }

    private func step(_ number: Int, _ title: String, done: Bool, detail: String, target: SidebarItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open") { model.selection = target }
        }
        .padding(.vertical, 2)
    }
}
