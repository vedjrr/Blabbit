import AppKit
import Observation
import SwiftUI

/// State of the "Change Shortcut" window.
@MainActor @Observable
public final class ShortcutRecorderModel {
    public private(set) var candidate: Shortcut?
    public private(set) var problem: String?
    /// nil when recording a shortcut that isn't set yet (the AI shortcut).
    public let current: Shortcut?
    /// The other binding's shortcut, which this one must differ from.
    public let other: Shortcut?
    public let title: String
    /// A modifier-only key that went down with nothing else yet.
    private var pendingModifier: UInt16?

    public init(current: Shortcut?, other: Shortcut? = nil, title: String = "Change Shortcut") {
        self.current = current
        self.other = other
        self.title = title
    }

    /// Feeds a key-down from the window. Returns true if it was used.
    @discardableResult
    public func record(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        pendingModifier = nil
        var flags = CGEventFlags()
        if modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: flags.rawValue)
        propose(shortcut)
        return true
    }

    /// Feeds a modifier change. fn or a right-side modifier pressed and released
    /// on its own becomes a modifier-only shortcut.
    public func recordFlagsChanged(keyCode: UInt16, rawFlags: UInt64) {
        let candidate = Shortcut(keyCode: keyCode, modifiers: 0)
        guard candidate.isModifierOnly else {
            pendingModifier = nil
            return
        }
        let flags = CGEventFlags(rawValue: rawFlags)
        if candidate.modifierIsDown(in: flags) {
            // Only if nothing else is held (⌘ then right ⌥ is a combo, not ours).
            let others = flags.intersection(Shortcut.relevantModifiers).subtracting(candidate.ownGenericFlag)
            pendingModifier = others.isEmpty ? keyCode : nil
        } else if pendingModifier == keyCode {
            pendingModifier = nil
            propose(candidate)
        }
    }

    private func propose(_ shortcut: Shortcut) {
        candidate = shortcut
        problem = shortcut.problem
        if problem == nil, let other, shortcut == other {
            problem = "\(shortcut.displayString) is already your other Utter shortcut."
        }
        if problem == nil, shortcut != current, CarbonHotkey.isTakenElsewhere(shortcut) {
            problem = HotkeyError.shortcutInUse(shortcut.displayString).userMessage
        }
    }

    /// fn only works on its own when macOS doesn't also use it.
    public var note: String? {
        guard candidate?.keyCode == 63 else { return nil }
        return "Tip: set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, so fn doesn't also open emoji or switch input."
    }

    public var canSave: Bool { candidate != nil && problem == nil && candidate != current }
}

struct ShortcutRecorderView: View {
    let model: ShortcutRecorderModel
    let onSave: (Shortcut) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title).font(.title3.weight(.semibold))
            Text("Press the keys you want to use, for example ⌥Space or ⌃⌥D, or press and release fn or a right-side modifier (Right ⌥) on its own. Esc cancels.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.candidate?.displayString ?? model.current?.displayString ?? "Press keys…")
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else if let note = model.note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if model.candidate == nil, let current = model.current {
                Text("Current: \(current.displayString)").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { if let c = model.candidate { onSave(c) } }
                    .disabled(!model.canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
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

    public var isOpen: Bool { window != nil }

    public func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func show(current: Shortcut?, other: Shortcut? = nil, title: String = "Change Shortcut",
                     onSave: @escaping (Shortcut) -> Void, onClose: @escaping () -> Void) {
        close()
        self.onClose = onClose
        let model = ShortcutRecorderModel(current: current, other: other, title: title)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self, weak window] event in
            guard let window, event.window === window else { return event }
            if event.type == .flagsChanged {
                model.recordFlagsChanged(keyCode: event.keyCode, rawFlags: UInt64(event.modifierFlags.rawValue))
                return event
            }
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
