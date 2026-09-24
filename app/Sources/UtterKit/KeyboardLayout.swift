import Carbon.HIToolbox
import CoreGraphics

/// Maps characters to virtual key codes for the current keyboard layout, so
/// synthetic shortcuts like ⌘V work on AZERTY, Dvorak, etc.
public enum KeyboardLayout {
    public static func keyCode(for character: Character) -> CGKeyCode? {
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
