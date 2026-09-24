import AppKit
import UtterCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--version") {
    print("Utter \(coreVersion())")
    exit(0)
}
app.run()
