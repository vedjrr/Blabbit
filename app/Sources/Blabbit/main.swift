import AppKit
import BlabbitCore
import BlabbitKit

if CommandLine.arguments.contains("--version") {
    print("Blabbit \(coreVersion())")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launching Blabbit again (Finder, Spotlight) opens Settings: the way back
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menu?.showSettings()
        return false
    }

    private let controller = DictationController(models: ModelManager())

    /// `make build` output inside a checkout (build/Blabbit.app next to the
    /// Makefile): never replaced by a release through Sparkle.
    static var isDevelopmentBuild: Bool {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        return folder.lastPathComponent == "build"
            && FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("Makefile").path)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
    private var menu: StatusMenuController?

    /// `blabbit://` links (PARITY F14), only when the user allowed them.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = RemoteCommand(url: url) else { Log.info("ignored url scheme=\(url.scheme ?? "")"); continue }
            guard GeneralSettings.load().allowURLCommands else {
                Log.info("url command \(command.rawValue) ignored: blabbit:// links are off (Settings → General)")
                continue
            }
            perform(command)
        }
    }

    private func perform(_ command: RemoteCommand) {
        if command == .settings { menu?.showSettings() } else { controller.perform(command) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions(arguments: CommandLine.arguments)
        let menu = StatusMenuController(controller: controller)
        menu.hideIconThisSession = options.noTray
        // Sparkle only in the real bundle (not the bench's second instance).
        if ProcessInfo.processInfo.environment["BLABBIT_BENCH_SECOND_INSTANCE"] == nil, !Self.isDevelopmentBuild {
            let updates = Updates()
            updates.isBusy = { [controller] in controller.state == .recording || controller.state == .transcribing }
            menu.updates = updates
        }
        if !options.startHidden {
            controller.onNeedsModel = { [weak menu] in menu?.showModelManager() }
            controller.onNeedsPermissions = { [weak menu] in menu?.showPermissions() }
        }
        if options.debug { Log.info("launch options debug=true start_hidden=\(options.startHidden) no_tray=\(options.noTray)") }
        self.menu = menu
        controller.launch()
        menu.updateVisibilityAtLaunch()
        DistributedNotificationCenter.default().addObserver(forName: showSettingsNotification, object: nil, queue: .main) { [weak menu] _ in
            MainActor.assumeIsolated { menu?.showSettings() }
        }
        // A second launch with a flag (`Blabbit --toggle-transcription`) sends it here.
        DistributedNotificationCenter.default().addObserver(forName: remoteCommandNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.object as? String, let command = RemoteCommand(rawValue: raw) else { return }
            MainActor.assumeIsolated { self?.perform(command) }
        }
        if CommandLine.arguments.contains("--model-manager") { menu.showModelManager() }
    }
}

/// Posted by a second launch; the running Blabbit opens Settings (the way back
/// when the menu bar icon is hidden). An LSUIElement app gets no reopen event.
let showSettingsNotification = Notification.Name("dev.blabbit.mac.showSettings")
let remoteCommandNotification = Notification.Name("dev.blabbit.mac.command")

// One Blabbit at a time: a second launch hands over to the running one and
// quits, so two event taps never fight over the shortcut.
// `make bench` measures a fresh launch next to the user's running copy.
if ProcessInfo.processInfo.environment["BLABBIT_BENCH_SECOND_INSTANCE"] == nil,
   let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    if let command = RemoteCommand(arguments: CommandLine.arguments) {
        DistributedNotificationCenter.default().postNotificationName(remoteCommandNotification, object: command.rawValue, userInfo: nil,
                                                                     deliverImmediately: true)
    } else {
        DistributedNotificationCenter.default().postNotificationName(showSettingsNotification, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
