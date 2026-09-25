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
        if CommandLine.arguments.contains("--model-manager") { menu.showModelManager() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
