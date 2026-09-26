import CoreGraphics
import Foundation

/// A key + modifier combination, e.g. ⌥Space.
public struct Shortcut: Equatable, Sendable, Codable {
    public var keyCode: UInt16
    /// Subset of `Shortcut.relevantModifiers`, as raw `CGEventFlags`.
    public var modifiers: UInt64

    public static let relevantModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    /// ⌥Space — the same default Handy uses on macOS.
    public static let optionSpace = Shortcut(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue)

    public init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Shortcut.relevantModifiers.rawValue
    }

    /// Keys that can be a shortcut on their own (hold fn, or a right-side
    /// modifier), with the device-dependent flag bit that says the key is down.
    /// Left-side modifiers are left out: they start too many ordinary combos.
    public static let modifierKeys: [UInt16: UInt64] = [
        63: CGEventFlags.maskSecondaryFn.rawValue, // fn / Globe
        54: 0x10,     // right ⌘ (NX_DEVICERCMDKEYMASK)
        61: 0x40,     // right ⌥ (NX_DEVICERALTKEYMASK)
        62: 0x2000,   // right ⌃ (NX_DEVICERCTLKEYMASK)
        60: 0x04,     // right ⇧ (NX_DEVICERSHIFTKEYMASK)
    ]

    /// A modifier key held by itself (e.g. fn), rather than key + modifiers.
    public var isModifierOnly: Bool { Self.modifierKeys[keyCode] != nil }

    /// The generic flag a modifier-only key also sets (⌥ for right ⌥); none for fn.
    var ownGenericFlag: CGEventFlags {
        switch keyCode {
        case 54: .maskCommand
        case 61: .maskAlternate
        case 62: .maskControl
        case 60: .maskShift
        default: []
        }
    }

    /// Whether a modifier-only key is down in `flags` (from a flagsChanged event
    /// or `CGEventSource.flagsState`).
    public func modifierIsDown(in flags: CGEventFlags) -> Bool {
        guard let mask = Self.modifierKeys[keyCode] else { return false }
        return flags.rawValue & mask != 0
    }

    /// For the watchdog: is the shortcut's key physically down right now?
    /// Reads the hardware (HID) state: the session state never sees a key our
    /// tap swallows, so it reports a held shortcut as up (that cut every
    /// hold-to-talk recording after 0.5 s).
    /// A modifier-only key whose state Say Less's own keystrokes have overwritten
    /// counts as down: its real release still reaches the tap as flagsChanged.
    public func isPhysicallyDown() -> Bool {
        if isModifierOnly {
            return SyntheticKeys.modifierStateIsStale || modifierIsDown(in: CGEventSource.flagsState(.hidSystemState))
        }
        return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }

    public var displayString: String {
        let f = CGEventFlags(rawValue: modifiers)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s + KeyboardLayout.name(for: keyCode)
    }

    public static let defaultsKey = "hotkey.shortcut"
    /// The optional second shortcut that dictates with an AI mode (PARITY A7).
    public static let processDefaultsKey = "hotkey.processShortcut"

    public static func load(from defaults: UserDefaults = .standard) -> Shortcut {
        loadOptional(key: defaultsKey, from: defaults) ?? .optionSpace
    }

    /// A saved shortcut, or nil if none is saved or it became invalid.
    public static func loadOptional(key: String, from defaults: UserDefaults = .standard) -> Shortcut? {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data),
              saved.problem == nil else { return nil }
        return saved
    }

    public func save(to defaults: UserDefaults = .standard) {
        save(key: Self.defaultsKey, to: defaults)
    }

    public func save(key: String, to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: key)
    }

    /// Shortcuts macOS or nearly every app already uses.
    static let reserved: [Shortcut] = [
        Shortcut(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue),                              // ⌘Space Spotlight
        Shortcut(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue),                              // ⌃Space input source
        Shortcut(keyCode: 49, modifiers: CGEventFlags([.maskControl, .maskCommand]).rawValue),            // ⌃⌘Space emoji
        Shortcut(keyCode: 48, modifiers: CGEventFlags.maskCommand.rawValue),                              // ⌘Tab
    ] + [12, 13, 8, 9, 7, 6, 0, 1, 3, 45, 46, 31, 4].map {                                                  // ⌘Q W C V X Z A S F N M O H
        Shortcut(keyCode: $0, modifiers: CGEventFlags.maskCommand.rawValue)
    }

    /// Why this can't be the dictation shortcut, or nil if it can.
    public var problem: String? {
        if keyCode == 53 { return "Esc can't be the shortcut." }
        let mods = CGEventFlags(rawValue: modifiers)
        if isModifierOnly {
            return mods.isEmpty ? nil : "\(KeyboardLayout.name(for: keyCode)) works on its own; don't combine it with other modifiers."
        }
        if mods.isEmpty && !KeyboardLayout.functionKeys.contains(keyCode) {
            return "Add ⌥, ⌃, ⇧ or ⌘ (or use an F-key), so typing that key still works."
        }
        if mods == .maskShift && !KeyboardLayout.functionKeys.contains(keyCode) {
            return "⇧ alone would block typing capital letters. Add ⌥, ⌃ or ⌘."
        }
        if Self.reserved.contains(self) { return "\(displayString) is already used by macOS or most apps." }
        return nil
    }
}

public enum KeyEventKind: Sendable { case keyDown, keyUp, flagsChanged }

public enum ShortcutAction: Equatable, Sendable {
    /// Let the event through to the focused app.
    case pass
    /// Consume the event (it belongs to our shortcut).
    case swallow
    /// Consume and start dictation.
    case press
    /// Consume and stop dictation.
    case release
    /// Esc while armed: consume it and cancel the dictation.
    case cancel
    /// A modifier-only shortcut turned out to be part of a combo: let the key
    /// through and abandon the recording it started.
    case abort
}

/// Pure push-to-talk state machine for a key shortcut. Runs on the event-tap thread.
public struct ShortcutMatcher: Sendable {
    public var shortcut: Shortcut {
        didSet { isHeld = false }
    }
    public private(set) var isHeld = false

    public init(shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    public mutating func handle(kind: KeyEventKind, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) -> ShortcutAction {
        if shortcut.isModifierOnly { return handleModifierOnly(kind: kind, keyCode: keyCode, flags: flags) }
        switch kind {
        case .flagsChanged:
            return .pass
        case .keyDown:
            guard keyCode == shortcut.keyCode else { return .pass }
            if isHeld { return .swallow } // auto-repeat while held
            let mods = flags.intersection(Shortcut.relevantModifiers).rawValue
            guard mods == shortcut.modifiers, !isRepeat else { return .pass }
            isHeld = true
            return .press
        case .keyUp:
            guard keyCode == shortcut.keyCode, isHeld else { return .pass }
            isHeld = false
            return .release
        }
    }

    /// A modifier held alone. Its flagsChanged events are never swallowed (that
    /// would leave the modifier stuck in other apps); another key pressed while
    /// it is held means the user was typing a combo, so the recording aborts.
    private mutating func handleModifierOnly(kind: KeyEventKind, keyCode: UInt16, flags: CGEventFlags) -> ShortcutAction {
        switch kind {
        case .flagsChanged:
            guard keyCode == shortcut.keyCode else { return .pass }
            let down = shortcut.modifierIsDown(in: flags)
            if down, !isHeld {
                // Already part of a combo (e.g. ⌘ held, then right ⌥): not ours.
                let others = flags.intersection(Shortcut.relevantModifiers).subtracting(shortcut.ownGenericFlag)
                guard others.isEmpty else { return .pass }
                isHeld = true
                return .press
            }
            if !down, isHeld {
                isHeld = false
                return .release
            }
            return .pass
        case .keyDown:
            guard isHeld else { return .pass }
            isHeld = false
            return .abort
        case .keyUp:
            return .pass
        }
    }

    /// Called if the tap was disabled while held, so we never get stuck recording.
    public mutating func reset() -> Bool {
        defer { isHeld = false }
        return isHeld
    }
}

/// Which shortcut an event belongs to.
public enum ShortcutBinding: Sendable, Equatable {
    /// The dictation shortcut.
    case dictate
    /// The second shortcut: dictate, then run an AI mode (PARITY A7).
    case process
}

/// Routes key events to the dictation shortcut, the optional AI shortcut and
/// the Esc cancel key (armed only while a dictation runs). Pure; tap thread.
public struct HotkeyRouter: Sendable {
    public var primary: ShortcutMatcher
    public var secondary: ShortcutMatcher?
    /// While true, Esc (no modifiers) cancels the dictation and is swallowed.
    public var cancelArmed = false
    private var escDown = false
    static let escKeyCode: UInt16 = 53

    public init(primary: Shortcut, secondary: Shortcut? = nil) {
        self.primary = ShortcutMatcher(shortcut: primary)
        self.secondary = secondary.map(ShortcutMatcher.init(shortcut:))
    }

    public mutating func handle(kind: KeyEventKind, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) -> (ShortcutAction, ShortcutBinding) {
        if keyCode == Self.escKeyCode, kind != .flagsChanged {
            if kind == .keyDown, cancelArmed, flags.intersection(Shortcut.relevantModifiers).isEmpty {
                escDown = true
                return (isRepeat ? .swallow : .cancel, .dictate)
            }
            // The key-up of a swallowed Esc belongs to us too.
            if kind == .keyUp, escDown {
                escDown = false
                return (.swallow, .dictate)
            }
        }
        let first = primary.handle(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        if first != .pass { return (first, .dictate) }
        if var second = secondary {
            let action = second.handle(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
            secondary = second
            return (action, .process)
        }
        return (.pass, .dictate)
    }

    /// Clears held state (tap disabled, watchdog). Returns the binding that was held.
    public mutating func reset() -> ShortcutBinding? {
        escDown = false
        let wasPrimary = primary.reset()
        let wasSecondary = secondary?.reset() ?? false
        return wasPrimary ? .dictate : (wasSecondary ? .process : nil)
    }
}
