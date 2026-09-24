import CoreGraphics
import Foundation
import os

public enum HotkeyError: Error, Equatable {
    /// CGEvent.tapCreate returned nil: Accessibility permission is missing.
    case tapCreationFailed

    public var userMessage: String {
        "Utter can't listen for its shortcut. Allow Utter in System Settings → Privacy & Security → Accessibility."
    }
}

/// Global push-to-talk shortcut via an active CGEventTap on a dedicated thread
/// (ADR-005). Matching key events are swallowed so they never reach the focused app.
public final class HotkeyMonitor: @unchecked Sendable {
    /// Called on the tap thread with the monotonic time of the key event.
    public var onPress: (@Sendable (UInt64) -> Void)?
    public var onRelease: (@Sendable (UInt64) -> Void)?

    private let matcher: OSAllocatedUnfairLock<ShortcutMatcher>
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    public init(shortcut: Shortcut = .optionSpace) {
        matcher = OSAllocatedUnfairLock(initialState: ShortcutMatcher(shortcut: shortcut))
    }

    public var shortcut: Shortcut {
        get { matcher.withLock { $0.shortcut } }
        set { matcher.withLock { $0.shortcut = newValue } }
    }

    public var isRunning: Bool { tap != nil }

    public func start() throws {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            throw HotkeyError.tapCreationFailed
        }
        self.tap = tap
        // CFMachPort is thread-safe to hand to the run-loop thread; it is only used there and in stop().
        nonisolated(unsafe) let machPort = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self, let source = CFMachPortCreateRunLoopSource(nil, machPort, 0) else { ready.signal(); return }
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: machPort, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "dev.utter.hotkey"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        Log.info("hotkey tap started shortcut=\(shortcut.displayString)")
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = MonoClock.nowNs()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables slow taps; turn it back on and never leave a key "held".
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if matcher.withLock({ $0.reset() }) { onRelease?(now) }
            Log.error("hotkey tap was disabled (\(type.rawValue)); re-enabled")
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            let kind: KeyEventKind = type == .keyDown ? .keyDown : (type == .keyUp ? .keyUp : .flagsChanged)
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let flags = event.flags
            let action = matcher.withLock { $0.handle(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat) }
            switch action {
            case .pass: return Unmanaged.passUnretained(event)
            case .swallow: return nil
            case .press:
                onPress?(now)
                return nil
            case .release:
                onRelease?(now)
                return nil
            }
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
