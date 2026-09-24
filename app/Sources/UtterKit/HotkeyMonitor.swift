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
public struct KeyTiming: Sendable {
    public var callbackNs: UInt64
    public var eventTimestamp: UInt64
}

public final class HotkeyMonitor: @unchecked Sendable {
    /// Called on the tap thread. `KeyTiming.callbackNs` is `MonoClock` time when
    /// the tap saw the event; `eventTimestamp` is the raw `CGEvent.timestamp`.
    public var onPress: (@Sendable (KeyTiming) -> Void)?
    public var onRelease: (@Sendable (KeyTiming) -> Void)?

    private let matcher: OSAllocatedUnfairLock<ShortcutMatcher>
    /// Carbon fallback registered while secure input is sustained (main thread only).
    private var carbon: CarbonHotkey?
    private var secureState = SecureInputState()
    private var secureTimer: Timer?
    /// Called on main when sustained secure input starts/stops (for UI notices).
    public var onSecureInputChange: (@MainActor (Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
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

    /// Clears a held state the tap may have missed the key-up for (watchdog).
    /// Returns true if the shortcut had been considered held.
    @discardableResult
    public func forceRelease() -> Bool {
        matcher.withLock { $0.reset() }
    }

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
            self.source = source
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
        DispatchQueue.main.async { self.startSecureInputWatch() }
    }

    /// Polls secure input once a second; while it is sustained, a Carbon hotkey
    /// stands in for the tap (which no longer sees key-downs).
    @MainActor
    private func startSecureInputWatch() {
        secureTimer?.invalidate()
        secureTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSecureInput() }
        }
    }

    @MainActor
    private func checkSecureInput() {
        guard secureState.observe(enabled: PasteInserter.secureInputActive, at: Date()) else { return }
        if secureState.sustained {
            let shortcut = self.shortcut
            carbon = CarbonHotkey(shortcut: shortcut, onPress: { [weak self] in self?.carbonEvent(down: true) },
                                  onRelease: { [weak self] in self?.carbonEvent(down: false) })
            Log.info("secure input sustained; carbon fallback \(carbon == nil ? "FAILED to register" : "registered") for \(shortcut.displayString)")
        } else {
            carbon = nil
            Log.info("secure input off; carbon fallback removed")
        }
        onSecureInputChange?(secureState.sustained)
    }

    /// Carbon events go through the same matcher so tap + Carbon can't double-fire.
    private func carbonEvent(down: Bool) {
        let shortcut = self.shortcut
        let timing = KeyTiming(callbackNs: MonoClock.nowNs(), eventTimestamp: 0)
        let action = matcher.withLock {
            $0.handle(kind: down ? .keyDown : .keyUp, keyCode: shortcut.keyCode,
                      flags: CGEventFlags(rawValue: shortcut.modifiers), isRepeat: false)
        }
        if action == .press { onPress?(timing) }
        if action == .release { onRelease?(timing) }
    }

    public func stop() {
        secureTimer?.invalidate()
        secureTimer = nil
        carbon = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        tap = nil
        source = nil
        runLoop = nil
        thread = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = KeyTiming(callbackNs: MonoClock.nowNs(), eventTimestamp: event.timestamp)
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
