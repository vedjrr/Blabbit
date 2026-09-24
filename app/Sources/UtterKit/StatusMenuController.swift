import AppKit
import UtterCore

/// The menu bar item: icon reflects dictation state; menu is rebuilt on open.
@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController

    public init(controller: DictationController) {
        self.controller = controller
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.onStateChange = { [weak self] state in self?.updateIcon(for: state) }
        updateIcon(for: controller.state)
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
        model.isEnabled = false
        menu.addItem(model)

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
    @objc private func openAccessibility() { NSWorkspace.shared.open(Permissions.accessibilitySettingsURL) }
    @objc private func retryHotkey() { controller.startHotkey() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }
}
