import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Inserts text as synthetic Unicode key events. Used where paste is blocked.
public enum TypingInserter {
    /// CGEvent accepts at most 20 UTF-16 units per event; never split a
    /// surrogate pair or a composed character across events.
    public static let maxUnitsPerEvent = 20

    public enum Piece: Equatable, Sendable {
        case text([UInt16])
        /// Newlines go as a real Return key so terminals and chat apps see Enter.
        case newline
    }

    /// Splits text into ≤ 20-unit chunks on grapheme boundaries, with newlines separate.
    public static func pieces(for text: String) -> [Piece] {
        var result: [Piece] = []
        var current: [UInt16] = []
        func flush() {
            if !current.isEmpty { result.append(.text(current)); current = [] }
        }
        for character in text {
            if character.isNewline {
                flush()
                result.append(.newline)
                continue
            }
            let units = Array(String(character).utf16)
            if current.count + units.count > maxUnitsPerEvent { flush() }
            if units.count > maxUnitsPerEvent {
                // A grapheme longer than one event (long emoji ZWJ sequences): split
                // it on Unicode-scalar boundaries so no surrogate pair is broken.
                flush()
                for scalar in String(character).unicodeScalars {
                    let scalarUnits = Array(String(scalar).utf16)
                    if current.count + scalarUnits.count > maxUnitsPerEvent { flush() }
                    current.append(contentsOf: scalarUnits)
                }
                flush()
            } else {
                current.append(contentsOf: units)
            }
        }
        flush()
        return result
    }

    public static let secureInputStoppedTyping = "Secure input turned on while typing, so Say Less stopped."

    /// Posts the pieces. Returns an error message or nil.
    @MainActor
    public static func type(_ text: String, secureInputActive: () -> Bool = { IsSecureEventInputEnabled() }) async -> String? {
        guard let source = SyntheticKeys.source() else { return "Could not create keyboard events." }
        // Keys the user is still releasing must not merge with the typed text.
        source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                          state: .eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0.05
        for piece in pieces(for: text) {
            // A long transcript takes a while to type; stop if a password field takes focus.
            if secureInputActive() { return secureInputStoppedTyping }
            switch piece {
            case .newline:
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { return "Could not create keyboard events." }
                down.flags = []
                up.flags = []
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            case .text(let units):
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return "Could not create keyboard events." }
                units.withUnsafeBufferPointer { buf in
                    down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                down.flags = []
                up.flags = []
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            // Pace events so slower apps (Electron, remote desktops) don't drop them.
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }
}
