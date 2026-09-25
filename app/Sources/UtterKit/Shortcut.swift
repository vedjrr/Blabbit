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

    public static func load(from defaults: UserDefaults = .standard) -> Shortcut {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data),
              saved.problem == nil else { return .optionSpace }
        return saved
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
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
}

/// Pure push-to-talk state machine for a key shortcut. Runs on the event-tap thread.
public struct ShortcutMatcher: Sendable {
    public var shortcut: Shortcut
    public private(set) var isHeld = false

    public init(shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    public mutating func handle(kind: KeyEventKind, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) -> ShortcutAction {
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

    /// Called if the tap was disabled while held, so we never get stuck recording.
    public mutating func reset() -> Bool {
        defer { isHeld = false }
        return isHeld
    }
}
