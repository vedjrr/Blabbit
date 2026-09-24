import Carbon.HIToolbox
import Foundation

/// Tracks macOS secure event input. A password field briefly enables it; when it
/// stays on (a stuck app, Terminal's Secure Keyboard Entry), event taps stop
/// seeing key-downs, so the shortcut needs a Carbon fallback (PARITY A8).
public struct SecureInputState: Sendable, Equatable {
    /// How long secure input must stay on before it counts as "sustained".
    public static let sustainThreshold: TimeInterval = 2

    public private(set) var enabledSince: Date?
    public private(set) var sustained = false

    public init() {}

    /// Feeds one observation; returns true if `sustained` changed.
    public mutating func observe(enabled: Bool, at now: Date) -> Bool {
        let before = sustained
        if enabled {
            if enabledSince == nil { enabledSince = now }
            sustained = now.timeIntervalSince(enabledSince!) >= Self.sustainThreshold
        } else {
            enabledSince = nil
            sustained = false
        }
        return sustained != before
    }
}

/// Carbon global hotkey. Not affected by secure input, but can't express
/// modifier-only shortcuts, so it is only a fallback.
final class CarbonHotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init?(shortcut: Shortcut, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<CarbonHotkey>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { hotkey.onPress() } else { hotkey.onRelease() }
            return noErr
        }, types.count, &types, context, &handler)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x5554_5452), id: 1) // 'UTTR'
        let registered = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers), id,
                                             GetApplicationEventTarget(), 0, &ref)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    static func carbonModifiers(_ cgFlags: UInt64) -> UInt32 {
        let flags = CGEventFlags(rawValue: cgFlags)
        var m: UInt32 = 0
        if flags.contains(.maskCommand) { m |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { m |= UInt32(optionKey) }
        if flags.contains(.maskControl) { m |= UInt32(controlKey) }
        if flags.contains(.maskShift) { m |= UInt32(shiftKey) }
        return m
    }
}
