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
        let shortcut = NSMenuItem(title: "Shortcut: hold \(controller.hotkey.shortcut.displayString)", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
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
        let managerItem = NSMenuItem(title: "Model Manager…", action: #selector(openModelManager), keyEquivalent: "m")
        managerItem.target = self
        menu.addItem(managerItem)

        if !Permissions.accessibilityGranted || !controller.hotkey.isRunning {
            menu.addItem(.separator())
            let grant = NSMenuItem(title: "Allow Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
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
    @objc private func openAccessibility() { NSWorkspace.shared.open(Permissions.accessibilitySettingsURL) }
    @objc private func retryHotkey() { controller.startHotkey() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }
}
