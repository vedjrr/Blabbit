import AppKit
import UtterCore
import UtterKit

if CommandLine.arguments.contains("--version") {
    print("Utter \(coreVersion())")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DictationController(models: ModelManager())
    private var menu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenuController(controller: controller)
        controller.onNeedsModel = { [weak menu] in menu?.showModelManager() }
        controller.onNeedsPermissions = { [weak menu] in menu?.showPermissions() }
        self.menu = menu
        controller.launch()
        if CommandLine.arguments.contains("--model-manager") { menu.showModelManager() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
