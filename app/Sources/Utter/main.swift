import AppKit
import UtterCore
import UtterKit

if CommandLine.arguments.contains("--version") {
    print("Utter \(coreVersion())")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DictationController()
    private var menu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenuController(controller: controller)
        controller.launch()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
