import AppKit
import UtterCore

/// The menu bar item: icon reflects dictation state; menu is rebuilt on open.
@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController
    private let modelWindow: ModelManagerWindowController

    public init(controller: DictationController) {
        self.controller = controller
        self.modelWindow = ModelManagerWindowController(manager: controller.models)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.onStateChange = { [weak self] state in
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
        let verb = controller.mode == .pushToTalk ? "hold" : "press"
        let shortcut = NSMenuItem(title: "Shortcut: \(verb) \(controller.hotkey.shortcut.displayString)", action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu()
        for mode in DictationMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(chooseMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = controller.mode == mode ? .on : .off
            shortcutMenu.addItem(item)
        }
        shortcutMenu.addItem(.separator())
        let change = NSMenuItem(title: "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "")
        change.target = self
        shortcutMenu.addItem(change)
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
    @objc private func openModelManager() { modelWindow.show() }

    private lazy var historyWindow = HistoryWindowController(controller: controller)
    private lazy var settingsWindow: SettingsWindowController = {
        let window = SettingsWindowController(controller: controller,
                                              openModelManager: { [weak self] in self?.modelWindow.show() },
                                              changeShortcut: { [weak self] in self?.changeShortcut() })
        window.model.onGeneralChange = { [weak self] general in
            self?.general = general
            self?.updateVisibility()
        }
        return window
    }()

    @objc private func openHistory() { historyWindow.show() }

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

    /// The icon hides when idle if the user chose so; it always shows while dictating.
    private func updateVisibility() {
        let busy = controller.state == .recording || controller.state == .transcribing
        statusItem.isVisible = general.showMenuBarIcon || busy
    }
    @objc private func chooseModel(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { controller.models.setDefault(id) }
    }

    /// Opens the Model Manager (e.g. first launch with no model).
    public func showModelManager() { modelWindow.show() }
    private let shortcutWindow = ShortcutRecorderWindowController()

    @objc private func chooseMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = DictationMode(rawValue: raw) { controller.setMode(mode) }
    }

    @objc private func changeShortcut() {
        if shortcutWindow.isOpen { shortcutWindow.bringToFront(); return }
        // A toggle-mode recording would have no way to stop while the tap is paused.
        if controller.state == .recording { controller.toggleFromMenu() }
        // The event tap would otherwise catch the current shortcut while recording a new one.
        controller.hotkey.stop()
        shortcutWindow.show(current: controller.hotkey.shortcut,
                            onSave: { [weak self] in self?.controller.setShortcut($0) },
                            onClose: { [weak self] in self?.controller.startHotkey() })
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
