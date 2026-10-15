import SwiftUI
import XperiaRescueCore

struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Page(
            title: "Setup & tools",
            subtitle: "newflasher is built into the app. adb and fastboot come from Google's official platform-tools, which the app downloads for you."
        ) {
            Card(title: "Command-line tools", systemImage: "hammer") {
                ForEach(ExternalTool.allCases, id: \.self) { tool in
                    toolRow(tool)
                    if tool != ExternalTool.allCases.last { Divider() }
                }
                HStack {
                    Button {
                        model.installPlatformTools()
                    } label: {
                        Label(model.toolPaths[.adb] == nil ? "Download adb & fastboot from Google" : "Update adb & fastboot", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.isInstallingPlatformTools)
                    if model.isInstallingPlatformTools {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Look Again") { model.refreshTools() }
                }
                if let error = model.platformToolsError {
                    Callout(style: .danger, text: "\(error)")
                }
                Text("Already using Homebrew? `brew install --cask android-platform-tools` works too; the app finds tools in /opt/homebrew/bin and /usr/local/bin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Card(title: "Folders", systemImage: "folder") {
                HStack {
                    Text("TA backups")
                    Spacer()
                    Button("Show in Finder") { model.revealInFinder(model.backupsDirectory) }
                }
                HStack {
                    Text("App support (platform-tools, scripts)")
                    Spacer()
                    Button("Show in Finder") { model.revealInFinder(model.supportDirectory) }
                }
            }

            Card(title: "macOS permissions", systemImage: "lock.shield") {
                Text("If macOS asks whether Xperia Rescue may access your Downloads or Documents folder, allow it, so newflasher can read the firmware there. No driver installation is needed on a Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(title: "Credits & licences", systemImage: "heart") {
                Text("**newflasher** by Munjeni, MIT licence: the Sony flash-mode protocol implementation that does the actual flashing.")
                Text("**libusb**, LGPL 2.1, bundled as a separate library used by newflasher.")
                Text("**Android SDK Platform-Tools** by Google, downloaded from dl.google.com under Google's terms; not redistributed by this app.")
                Text("Not affiliated with or endorsed by Sony. Xperia is a trademark of Sony Group Corporation.")
                    .foregroundStyle(.secondary)
                HStack {
                    Link("newflasher on GitHub", destination: URL(string: "https://github.com/munjeni/newflasher")!)
                    Link("libusb", destination: URL(string: "https://libusb.info")!)
                }
            }
        }
    }

    private func toolRow(_ tool: ExternalTool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: model.toolPaths[tool] == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(model.toolPaths[tool] == nil ? (tool == .newflasher ? Color.red : Color.orange) : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(tool.title).font(.body.weight(.semibold))
                    if let version = model.toolVersions[tool] {
                        Text(version).foregroundStyle(.secondary)
                    }
                }
                Text(model.toolPaths[tool]?.path ?? missingText(tool))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let path = model.toolPaths[tool] {
                Button("Reveal") { model.revealInFinder(path) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func missingText(_ tool: ExternalTool) -> String {
        switch tool {
        case .newflasher:
            return "Not found. Release builds of the app include it. For a development build run scripts/build-app.sh, or put a newflasher binary in ~/Library/Application Support/XperiaRescue/bin."
        case .adb, .fastboot:
            return "Not installed (optional: needed only for the Fastboot and ADB tools)."
        }
    }
}
