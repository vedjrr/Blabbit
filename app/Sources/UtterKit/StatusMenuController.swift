import AppKit
import SwiftUI
import UtterCore

/// The menu bar item: icon reflects dictation state; menu is rebuilt on open.
@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController

    public var updates: Updates?

    /// Left click opens the panel; right click (or ⌃-click) the classic menu.
    private let menu = NSMenu()
    private let popover = NSPopover()
    private let panel: MenuPanelModel

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            statusItem.menu = menu
            sender.performClick(nil) // shows the menu
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            panel.refresh()
            panel.copied = false
            // Utter isn't activated: the app you were typing in stays frontmost,
            // so a dictation started from the panel lands there.
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            watchForOutsideActivity()
        }
    }

    private var outsideClickMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?

    /// `.transient` only notices clicks inside Utter, and the panel never
    /// activates Utter, so a click in another app or switching apps left it
    /// open. Watch for both while it's shown.
    private func watchForOutsideActivity() {
        stopWatchingOutsideActivity()
        // Global mouse monitors see other apps' clicks only (no permission needed),
        // so clicks inside the panel and on the status item still work.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A click in the panel itself can reach here while Utter isn't
                // active yet; closing then would swallow the button's action.
                if let frame = self.popover.contentViewController?.view.window?.frame,
                   NSMouseInRect(NSEvent.mouseLocation, frame, false) { return }
                self.popover.performClose(nil)
            }
        }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // Clicking the panel activates Utter itself: that's not leaving it.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func stopWatchingOutsideActivity() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
    }

    public func popoverDidClose(_ notification: Notification) { stopWatchingOutsideActivity() }

    public init(controller: DictationController) {
        self.controller = controller
        panel = MenuPanelModel(controller: controller)
        super.init()
        menu.delegate = self
        panel.open = { [weak self] section in self?.settingsWindow.show(section) }
        panel.openPermissions = { [weak self] in self?.showPermissions() }
        panel.close = { [weak self] in self?.popover.performClose(nil) }
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        let hosting = NSHostingController(rootView: MenuPanelView(model: panel))
        // The popover follows the panel's own size (it grows when a notice or
        // the last dictation appears), never wider than the panel.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        controller.onStateChange = { [weak self] state in
            self?.panel.refresh()
            self?.cueReset?.cancel()
            self?.statusItem.button?.toolTip = nil
            self?.updateIcon(for: state)
            self?.updateVisibility()
        }
        controller.onAttention = { [weak self] cue in self?.showCue(cue) }
        updateIcon(for: controller.state)
    }

    private var cueReset: Task<Void, Never>?
    /// How long the attention icon stays before the normal icon returns.
    static let cueDuration: Duration = .seconds(4)

    /// Swaps the icon for a few seconds so a blocked or unconfirmed dictation
    /// is noticed without opening the menu; the tooltip carries the message.
    private func showCue(_ cue: AttentionCue) {
        let symbol = cue.symbolName
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: controller.lastMessage ?? "Utter")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = controller.lastMessage
        cueReset?.cancel()
        cueReset = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.cueDuration)) != nil, let self else { return }
            self.statusItem.button?.toolTip = nil
            self.updateIcon(for: self.controller.state)
        }
    }

    private func updateIcon(for state: DictationController.State) {
        let symbol: String
        switch state {
        case .recording: symbol = "waveform.circle.fill"
        case .transcribing: symbol = "ellipsis.circle"
        case .failed: symbol = "exclamationmark.triangle"
        case .starting, .loadingModel: symbol = "hourglass"
        case .ready: symbol = "waveform"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Utter")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let notice = controller.secureInputNotice {
            let item = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let message = controller.lastMessage, controller.state != .failed(message) {
            let note = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())

        let recording = controller.state == .recording
        let toggle = NSMenuItem(title: recording ? "Stop Dictation" : "Start Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = controller.modelLoaded || recording
        menu.addItem(toggle)
        if recording || controller.state == .transcribing {
            let cancel = NSMenuItem(title: "Cancel Dictation (Esc)", action: #selector(cancelDictation), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }
        let shortcut = NSMenuItem(title: "Shortcut: \(controller.mode.verb) \(controller.hotkey.shortcut.displayString)", action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu()
        for mode in DictationMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(chooseMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = controller.mode == mode ? .on : .off
            shortcutMenu.addItem(item)
        }
        shortcutMenu.addItem(.separator())
        let change = NSMenuItem(title: "Change Shortcut…", action: #selector(changeDictationShortcut), keyEquivalent: "")
        change.target = self
        shortcutMenu.addItem(change)
        let ai = NSMenuItem(title: controller.hotkey.processShortcut.map { "AI Shortcut: \($0.displayString) (\(controller.processMode.title))…" } ?? "Set AI Shortcut…",
                            action: #selector(changeProcessShortcut), keyEquivalent: "")
        ai.target = self
        shortcutMenu.addItem(ai)
        shortcut.submenu = shortcutMenu
        menu.addItem(shortcut)
        let textMode = NSMenuItem(title: "Mode: \(controller.textSettings.mode.title)", action: nil, keyEquivalent: "")
        let textModeMenu = NSMenu()
        for mode in TextPipelineSettings.Mode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(chooseTextMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = controller.textSettings.mode == mode ? .on : .off
            item.toolTip = mode.summary
            textModeMenu.addItem(item)
        }
        textMode.submenu = textModeMenu
        menu.addItem(textMode)
        let model = NSMenuItem(title: "Model: \(controller.modelName)\(controller.modelLoaded ? "" : " (not loaded)")", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for entry in controller.models.installedEntries {
            let item = NSMenuItem(title: entry.name, action: #selector(chooseModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.state = entry.id == controller.models.defaultModelID ? .on : .off
            modelMenu.addItem(item)
        }
        if !controller.models.installedEntries.isEmpty { modelMenu.addItem(.separator()) }
        let manage = NSMenuItem(title: "Model Manager…", action: #selector(openModelManager), keyEquivalent: "")
        manage.target = self
        modelMenu.addItem(manage)
        model.submenu = modelMenu
        menu.addItem(model)

        let mic = NSMenuItem(title: "Microphone: \(controller.microphoneName ?? "System Default")", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let chosen = controller.preferredMicrophoneUID
        let devices = AudioDeviceCache.shared.devices // kept current off main; no HAL call here
        let defaultName = AudioDeviceCache.shared.defaultDevice?.name
        let followDefault = NSMenuItem(title: "System Default" + (defaultName.map { " (\($0))" } ?? ""), action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
        followDefault.target = self
        followDefault.state = chosen == nil ? .on : .off
        micMenu.addItem(followDefault)
        micMenu.addItem(.separator())
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == chosen ? .on : .off
            micMenu.addItem(item)
        }
        micMenu.addItem(.separator())
        let ready = NSMenuItem(title: "Keep Microphone Ready (instant start)", action: #selector(toggleKeepReady), keyEquivalent: "")
        ready.target = self
        ready.state = controller.keepMicrophoneReady ? .on : .off
        ready.toolTip = "Keeps the microphone running between dictations so recording starts instantly and catches the first syllable. macOS shows the microphone indicator the whole time. With a Bluetooth headset microphone, the headset stays in its lower-quality call mode while this is on. Audio is never stored or sent."
        micMenu.addItem(ready)
        mic.submenu = micMenu
        menu.addItem(mic)
        let managerItem = NSMenuItem(title: "Model Manager…", action: #selector(openModelManager), keyEquivalent: "m")
        managerItem.target = self
        menu.addItem(managerItem)

        if !PermissionSnapshot.current().allGranted || !controller.hotkey.isRunning {
            menu.addItem(.separator())
            let setup = NSMenuItem(title: "Set Up Permissions…", action: #selector(openPermissions), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
            let retry = NSMenuItem(title: "Retry Shortcut", action: #selector(retryHotkey), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }

        menu.addItem(.separator())
        let copyLast = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLastDictation), keyEquivalent: "")
        copyLast.target = self
        copyLast.isEnabled = !(controller.lastPipeline?.final.isEmpty ?? true)
        menu.addItem(copyLast)
        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "y")
        history.target = self
        menu.addItem(history)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        if let updates, !updates.isLocked {
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self
            menu.addItem(check)
        }
        let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(NSMenuItem(title: "Quit Utter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var statusLine: String {
        switch controller.state {
        case .starting: "Starting…"
        case .loadingModel: "Loading \(controller.modelName)…"
        case .ready: "Ready"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .failed(let message): message
        }
    }

    @objc private func toggleDictation() { controller.toggleFromMenu() }
    @objc private func cancelDictation() { controller.cancelDictation(reason: "menu") }
    @objc private func openModelManager() { settingsWindow.show(.models) }

    private lazy var settingsWindow: SettingsWindowController = {
        let window = SettingsWindowController(controller: controller, updates: updates,
                                              changeShortcut: { [weak self] binding in self?.changeShortcut(binding) })
        window.model.onGeneralChange = { [weak self] general in
            self?.general = general
            self?.updateVisibility()
        }
        return window
    }()

    @objc private func openHistory() { settingsWindow.show(.history) }
    @objc private func checkForUpdates() { updates?.checkForUpdates() }

    @objc private func copyLastDictation() {
        guard let text = controller.lastPipeline?.final else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func openSettings() { settingsWindow.show() }
    public func showSettings() { settingsWindow.show() }
    public func updateVisibilityAtLaunch() { updateVisibility() }

    @objc private func chooseTextMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TextPipelineSettings.Mode(rawValue: raw) else { return }
        controller.textSettings.mode = mode
    }

    private var general = GeneralSettings.load()
    /// `--no-tray`: no icon this session, except while dictating.
    public var hideIconThisSession = false { didSet { updateVisibility() } }

    /// The icon hides when idle if the user chose so; it always shows while dictating.
    private func updateVisibility() {
        let busy = controller.state == .recording || controller.state == .transcribing
        statusItem.isVisible = (general.showMenuBarIcon && !hideIconThisSession) || busy
    }
    @objc private func chooseModel(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { controller.models.setDefault(id) }
    }

    /// Opens the Model Manager (e.g. first launch with no model).
    public func showModelManager() { settingsWindow.show(.models) }
    private let shortcutWindow = ShortcutRecorderWindowController()

    @objc private func chooseMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = DictationMode(rawValue: raw) { controller.setMode(mode) }
    }

    @objc private func changeDictationShortcut() { changeShortcut(.dictate) }
    @objc private func changeProcessShortcut() { changeShortcut(.process) }

    private func changeShortcut(_ binding: ShortcutBinding) {
        if shortcutWindow.isOpen { shortcutWindow.bringToFront(); return }
        // A toggle-mode recording would have no way to stop while the tap is paused.
        if controller.state == .recording { controller.toggleFromMenu() }
        // The event tap would otherwise catch the current shortcut while recording a new one.
        controller.hotkey.stop()
        let primary = controller.hotkey.shortcut
        let process = controller.hotkey.processShortcut
        switch binding {
        case .dictate:
            shortcutWindow.show(current: primary, other: process,
                                onSave: { [weak self] in self?.controller.setShortcut($0) },
                                onClose: { [weak self] in self?.controller.startHotkey() })
        case .process:
            shortcutWindow.show(current: process, other: primary, title: "AI Shortcut (\(controller.processMode.title) mode)",
                                onSave: { [weak self] in self?.controller.setProcessShortcut($0) },
                                onClose: { [weak self] in self?.controller.startHotkey() })
        }
    }

    @objc private func toggleKeepReady() { controller.setKeepMicrophoneReady(!controller.keepMicrophoneReady) }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        controller.selectMicrophone(uid: sender.representedObject as? String)
    }

    @objc private func retryHotkey() { controller.startHotkey(prompt: true) }

    private lazy var permissionsWindow: PermissionsWindowController = {
        let window = PermissionsWindowController()
        window.model.onChange = { [weak self] snapshot in self?.controller.permissionsChanged(snapshot) }
        return window
    }()

    /// Opens the permission setup window (first launch or from the menu).
    public func showPermissions() {
        permissionsWindow.model.shortcutDisplay = controller.hotkey.shortcut.displayString
        permissionsWindow.show()
    }

    @objc private func openPermissions() { showPermissions() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }
}
