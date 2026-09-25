import AppKit
import UtterCore
import UtterKit

if CommandLine.arguments.contains("--version") {
    print("Utter \(coreVersion())")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launching Utter again (Finder, Spotlight) opens Settings: the way back
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menu?.showSettings()
        return false
    }

    private let controller = DictationController(models: ModelManager())
    private var menu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenuController(controller: controller)
        controller.onNeedsModel = { [weak menu] in menu?.showModelManager() }
        controller.onNeedsPermissions = { [weak menu] in menu?.showPermissions() }
        self.menu = menu
        controller.launch()
        menu.updateVisibilityAtLaunch()
        DistributedNotificationCenter.default().addObserver(forName: showSettingsNotification, object: nil, queue: .main) { [weak menu] _ in
            MainActor.assumeIsolated { menu?.showSettings() }
        }
        if CommandLine.arguments.contains("--model-manager") { menu.showModelManager() }
    }
}

/// Posted by a second launch; the running Utter opens Settings (the way back
/// when the menu bar icon is hidden). An LSUIElement app gets no reopen event.
let showSettingsNotification = Notification.Name("dev.utter.mac.showSettings")

// One Utter at a time: a second launch hands over to the running one and
// quits, so two event taps never fight over the shortcut.
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    DistributedNotificationCenter.default().postNotificationName(showSettingsNotification, object: nil, userInfo: nil,
                                                                 deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
