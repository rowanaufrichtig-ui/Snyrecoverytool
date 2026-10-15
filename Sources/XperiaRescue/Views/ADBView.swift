import SwiftUI
import XperiaRescueCore

struct ADBView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Page(
            title: "ADB tools",
            subtitle: "Only useful if Android boots far enough with USB debugging enabled. ADB can't install Sony firmware (Sony doesn't publish sideloadable packages), but it can reboot into fastboot or recovery and capture the log that explains a bootloop."
        ) {
            if model.toolPaths[.adb] == nil {
                Callout(style: .warning, text: "adb isn't installed yet. Open **Setup & Tools** to download Google's platform-tools.")
                Button("Open Setup & Tools") { model.selection = .setup }
            }

            Card(title: "Devices", systemImage: "iphone") {
                HStack {
                    ModeBadge(mode: model.usbMode)
                    Spacer()
                    Button {
                        Task { await model.refreshADB() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy || model.toolPaths[.adb] == nil)
                }
                if model.adbDevices.isEmpty {
                    Text("No adb devices. A bootlooping phone usually isn't reachable over adb; use flash mode instead.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.adbDevices, id: \.self) { device in
                        HStack {
                            Text(device.serial).font(.system(.body, design: .monospaced))
                            Text(device.state).foregroundStyle(device.isAuthorized ? Color.green : Color.orange)
                            if let deviceModel = device.model { Text(deviceModel).foregroundStyle(.secondary) }
                        }
                    }
                    if model.adbDevices.contains(where: { $0.state == "unauthorized" }) {
                        Callout(style: .info, text: "Unlock the phone and tap **Allow** on the \"Allow USB debugging?\" prompt, then click Refresh.")
                    }
                }
            }

            if !model.adbProperties.isEmpty {
                Card(title: "Phone details", systemImage: "info.circle") {
                    KeyValueGrid(rows: propertyRows)
                }
            }

            Card(title: "Actions", systemImage: "bolt.horizontal") {
                HStack {
                    Button("Reboot to Fastboot") { model.adbReboot("bootloader") }
                    Button("Reboot to Recovery") { model.adbReboot("recovery") }
                    Button("Reboot") { model.adbReboot(nil) }
                    Spacer()
                    Button {
                        model.saveLogcat()
                    } label: {
                        Label("Save Logcat…", systemImage: "doc.text.magnifyingglass")
                    }
                }
                .disabled(model.isBusy || model.primaryADBSerial == nil)
                Text("There is no adb command for Sony's flash mode: turn the phone off and hold Volume Down while plugging in instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var propertyRows: [(String, String)] {
        let keys: [(String, String)] = [
            ("ro.product.model", "Model"),
            ("ro.product.device", "Device"),
            ("ro.build.display.id", "Build"),
            ("ro.build.version.release", "Android"),
            ("ro.build.version.security_patch", "Security patch"),
            ("ro.boot.slot_suffix", "Active slot"),
            ("ro.boot.verifiedbootstate", "Verified boot"),
            ("ro.boot.flash.locked", "Bootloader locked"),
        ]
        return keys.compactMap { key, title in
            model.adbProperties[key].map { (title, $0) }
        }
    }
}
