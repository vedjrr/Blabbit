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
        let symbol = cue == .blocked ? "lock.fill" : "exclamationmark.bubble"
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
        let defaultName = AudioDevices.defaultInput()?.name
        let followDefault = NSMenuItem(title: "System Default" + (defaultName.map { " (\($0))" } ?? ""), action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
        followDefault.target = self
        followDefault.state = chosen == nil ? .on : .off
        micMenu.addItem(followDefault)
        micMenu.addItem(.separator())
        for device in AudioDevices.inputDevices() {
            let item = NSMenuItem(title: device.name, action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == chosen ? .on : .off
            micMenu.addItem(item)
        }
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
        // The event tap would otherwise catch the current shortcut while recording a new one.
        controller.hotkey.stop()
        shortcutWindow.show(current: controller.hotkey.shortcut,
                            onSave: { [weak self] in self?.controller.setShortcut($0) },
                            onClose: { [weak self] in self?.controller.startHotkey() })
    }

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
