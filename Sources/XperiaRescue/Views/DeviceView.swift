import SwiftUI
import XperiaRescueCore

struct DeviceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Page(
            title: "Connect the phone",
            subtitle: "The Xperia 5 V has no notification light, so watch the status below: it updates by itself as soon as the phone shows up on USB."
        ) {
            statusCard

            Card(title: "1. Turn the bootlooping phone off", systemImage: "power") {
                StepRow(number: 1, text: "Unplug the USB cable.")
                StepRow(number: 2, text: "Press and hold **Power + Volume Up** together. The phone vibrates once (that would restart it); **keep holding** until it vibrates **three times**, then let go. The phone is now off.")
                StepRow(number: 3, text: "If nothing happens, hold both keys for up to 2 minutes, ignoring the vibrations, then release.")
            }

            Card(title: "2. Enter flash mode (to install stock firmware)", systemImage: "bolt.circle") {
                StepRow(number: 1, text: "With the phone off, press and hold **Volume Down**.")
                StepRow(number: 2, text: "While holding it, plug the USB cable (already connected to the Mac) into the phone.")
                StepRow(number: 3, text: "Keep holding until the status above says **Flash mode**, then release. The screen stays black, which is normal.")
                Text("If the phone starts booting instead, it wasn't fully off or Volume Down wasn't held early enough. Turn it off and try again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(title: "Optional: fastboot mode", systemImage: "terminal") {
                StepRow(number: 1, text: "With the phone off, hold **Volume Up** and plug in the USB cable.")
                Text("Fastboot is useful to read bootloader information, switch the active slot, or flash single images on an **unlocked** bootloader. Stock firmware is installed from flash mode instead.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.usbDevices.isEmpty {
                Card(title: "Sony USB devices", systemImage: "list.bullet.rectangle") {
                    ForEach(model.usbDevices, id: \.self) { device in
                        HStack {
                            ModeBadge(mode: USBModeClassifier.mode(of: device) ?? .android)
                            Text(device.idString).font(.system(.body, design: .monospaced))
                            if let name = device.productName { Text(name) }
                            if let serial = device.serialNumber { Text(serial).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        Card(title: "Status", systemImage: model.usbMode.systemImage) {
            HStack(spacing: 14) {
                Image(systemName: model.usbMode.systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(model.usbMode.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.usbMode.title).font(.title2.weight(.semibold))
                    Text(statusDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if let deviceModel = model.deviceModel {
                HStack {
                    Label("Model \(deviceModel)", systemImage: "checkmark.seal")
                    if let source = model.deviceModelSource {
                        Text("(read via \(source))").foregroundStyle(.secondary)
                    }
                    if let variant = XperiaCatalog.variant(forModel: deviceModel) {
                        Text("· \(variant.market)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { model.forgetDeviceModel() }
                        .help("Clear the remembered model, e.g. after connecting a different phone")
                }
            }
            HStack {
                switch model.usbMode {
                case .flashMode:
                    Button {
                        model.readPhoneAndBackUpTA()
                    } label: {
                        Label("Read Phone & Back Up TA", systemImage: "arrow.down.doc")
                    }
                    .disabled(model.isBusy || model.toolPaths[.newflasher] == nil)
                    Button("Go to Flash Stock ROM") { model.selection = .flash }
                        .buttonStyle(.borderedProminent)
                case .fastboot:
                    Button("Open Fastboot Tools") { model.selection = .fastboot }
                case .android:
                    Button("Open ADB Tools") { model.selection = .adb }
                case .notConnected:
                    EmptyView()
                }
            }
        }
    }

    private var statusDetail: String {
        switch model.usbMode {
        case .flashMode: return "Ready. Stock firmware can be flashed now."
        case .fastboot: return "The bootloader is waiting for fastboot commands."
        case .android: return "The phone is on (booting, in recovery, or charging). To flash, turn it off and enter flash mode."
        case .notConnected: return "No Sony device found on USB. Follow the steps below."
        }
    }
}
