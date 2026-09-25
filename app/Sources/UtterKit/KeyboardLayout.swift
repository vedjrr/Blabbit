import Carbon.HIToolbox
import Foundation
import CoreGraphics

/// Maps characters to virtual key codes for the current keyboard layout, so
/// synthetic shortcuts like ⌘V work on AZERTY, Dvorak, etc.
public enum KeyboardLayout {
    /// Keys whose label isn't a character of the layout.
    static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 117: "⌦", 115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    public static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// TIS/TSM aborts the process if called from two threads at once, and UI
    /// apps must call it on the main thread. All TIS use goes through this lock,
    /// and off the main thread only cached results are used.
    private static let tisLock = NSLock()
    nonisolated(unsafe) private static var nameCache: [UInt16: String] = [:]

    /// What the key is labelled on the current layout ("Space", "F5", "D").
    /// Off the main thread, returns the last name computed on it.
    public static func name(for keyCode: UInt16) -> String {
        if let named = namedKeys[keyCode] { return named }
        tisLock.lock()
        defer { tisLock.unlock() }
        guard Thread.isMainThread else { return nameCache[keyCode] ?? "Key \(keyCode)" }
        let name = layoutName(for: keyCode)
        nameCache[keyCode] = name
        return name
    }

    private static func layoutName(for keyCode: UInt16) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "Key \(keyCode)" }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
            guard status == noErr, length > 0 else { return "Key \(keyCode)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }

    public static func keyCode(for character: Character) -> CGKeyCode? {
        tisLock.lock()
        defer { tisLock.unlock() }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
