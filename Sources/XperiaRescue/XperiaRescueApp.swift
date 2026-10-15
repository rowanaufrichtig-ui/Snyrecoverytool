import AppKit
import SwiftUI

@main
struct XperiaRescueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Xperia Rescue", id: "main") {
            ContentView()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Link("newflasher on GitHub", destination: URL(string: "https://github.com/munjeni/newflasher")!)
                Link("Xperia 5 V: Restarting and Resetting (Sony)", destination: URL(string: "https://helpguide.sony.net/mobile/xperia-5m5/v1/en/contents/restart_reset_device.html")!)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is started outside an .app bundle (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isFlashing else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Flashing is in progress"
        alert.informativeText = "Quitting now interrupts newflasher and can leave the phone unable to boot until it is flashed again."
        alert.addButton(withTitle: "Keep Flashing")
        alert.addButton(withTitle: "Quit Anyway")
        if alert.runModal() == .alertSecondButtonReturn {
            model.stopActiveJob()
            return .terminateNow
        }
        return .terminateCancel
    }
}
