import AppKit
import Observation
import SwiftUI

/// State of the "Change Shortcut" window.
@MainActor @Observable
public final class ShortcutRecorderModel {
    public private(set) var candidate: Shortcut?
    public private(set) var problem: String?
    public let current: Shortcut

    public init(current: Shortcut) {
        self.current = current
    }

    /// Feeds a key-down from the window. Returns true if it was used.
    @discardableResult
    public func record(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        var flags = CGEventFlags()
        if modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: flags.rawValue)
        candidate = shortcut
        problem = shortcut.problem
        return true
    }

    public var canSave: Bool { candidate != nil && problem == nil && candidate != current }
}

struct ShortcutRecorderView: View {
    let model: ShortcutRecorderModel
    let onSave: (Shortcut) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Shortcut").font(.title3.weight(.semibold))
            Text("Press the keys you want to use, for example ⌥Space or ⌃⌥D. Esc cancels.")
                .font(.callout).foregroundStyle(.secondary)
            Text(model.candidate?.displayString ?? model.current.displayString)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else if model.candidate == nil {
                Text("Current: \(model.current.displayString)").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { if let c = model.candidate { onSave(c) } }
                    .disabled(!model.canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// A small window that captures the next key combination.
@MainActor
public final class ShortcutRecorderWindowController {
    private var window: NSWindow?
    private var monitor: Any?
    private var closeObserver: NSObjectProtocol?
    /// Called whenever the window goes away (saved, cancelled or closed).
    private var onClose: (() -> Void)?

    public init() {}

    public func show(current: Shortcut, onSave: @escaping (Shortcut) -> Void, onClose: @escaping () -> Void) {
        close()
        self.onClose = onClose
        let model = ShortcutRecorderModel(current: current)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Utter Shortcut"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ShortcutRecorderView(
            model: model,
            onSave: { [weak self] shortcut in onSave(shortcut); self?.close() },
            onCancel: { [weak self] in self?.close() }))
        window.center()
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // Our own window is key, so the key events come here (not to the event
        // tap's matcher, which only reacts to the current shortcut).
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let window, event.window === window else { return event }
            if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                self?.close()
                return nil
            }
            model.record(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
            return nil
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window?.orderOut(nil)
        window = nil
        let done = onClose
        onClose = nil
        done?()
    }
}
