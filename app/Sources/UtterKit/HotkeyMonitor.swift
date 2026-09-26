import CoreGraphics
import Foundation
import os

public enum HotkeyError: Error, Equatable {
    /// CGEvent.tapCreate returned nil: Accessibility permission is missing.
    case tapCreationFailed
    /// Another app registered the same global shortcut.
    case shortcutInUse(String)

    public var userMessage: String {
        switch self {
        case .tapCreationFailed:
            "Utter can't listen for its shortcut. Allow Utter in System Settings → Privacy & Security → Accessibility."
        case .shortcutInUse(let shortcut):
            "Another app already uses \(shortcut). Choose a different shortcut in Settings → Dictation."
        }
    }
}

/// Global push-to-talk shortcut via an active CGEventTap on a dedicated thread
/// (ADR-005). Matching key events are swallowed so they never reach the focused app.
public struct KeyTiming: Sendable {
    public var callbackNs: UInt64
    public var eventTimestamp: UInt64
    public var source: RecordingSource = .tap
    public var binding: ShortcutBinding = .dictate
}

public final class HotkeyMonitor: @unchecked Sendable {
    /// Called on the tap thread. `KeyTiming.callbackNs` is `MonoClock` time when
    /// the tap saw the event; `eventTimestamp` is the raw `CGEvent.timestamp`.
    public var onPress: (@Sendable (KeyTiming) -> Void)?
    public var onRelease: (@Sendable (KeyTiming) -> Void)?
    /// Esc while a dictation runs (see `cancelArmed`).
    public var onCancel: (@Sendable () -> Void)?
    /// A modifier-only shortcut was part of a combo: drop that recording.
    public var onAbort: (@Sendable () -> Void)?

    private let matcher: OSAllocatedUnfairLock<HotkeyRouter>
    /// Carbon fallbacks registered while secure input is sustained (main thread only).
    private var carbon: [CarbonHotkey] = []
    private var secureState = SecureInputState()
    private var secureTimer: Timer?
    /// Called on main when sustained secure input starts/stops (for UI notices).
    public var onSecureInputChange: (@MainActor (Bool) -> Void)?
    /// The Carbon fallback couldn't register the shortcut (another app has it).
    public var onShortcutConflict: (@MainActor (HotkeyError) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    public init(shortcut: Shortcut = .optionSpace, processShortcut: Shortcut? = nil) {
        matcher = OSAllocatedUnfairLock(initialState: HotkeyRouter(primary: shortcut, secondary: processShortcut))
    }

    public var shortcut: Shortcut {
        get { matcher.withLock { $0.primary.shortcut } }
        set {
            matcher.withLock { $0.primary.shortcut = newValue }
            // A registered Carbon fallback must follow the new shortcut.
            DispatchQueue.main.async { if self.secureState.sustained { self.registerCarbon() } }
        }
    }

    /// The second shortcut that dictates with an AI mode (nil: none).
    public var processShortcut: Shortcut? {
        get { matcher.withLock { $0.secondary?.shortcut } }
        set {
            matcher.withLock { $0.secondary = newValue.map(ShortcutMatcher.init(shortcut:)) }
            DispatchQueue.main.async { if self.secureState.sustained { self.registerCarbon() } }
        }
    }

    /// Esc cancels only while a dictation runs; otherwise it is left alone.
    public var cancelArmed: Bool {
        get { matcher.withLock { $0.cancelArmed } }
        set { matcher.withLock { $0.cancelArmed = newValue } }
    }

    public var isRunning: Bool { tap != nil }

    /// Clears a held state the tap may have missed the key-up for (watchdog).
    /// Returns true if the shortcut had been considered held.
    @discardableResult
    public func forceRelease() -> Bool {
        matcher.withLock { $0.reset() } != nil
    }

    public func start() throws {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // `make bench`'s second instance only listens, so it can't swallow
            // the user's shortcut while it measures start-up.
            options: ProcessInfo.processInfo.environment["UTTER_BENCH_SECOND_INSTANCE"] == nil ? .defaultTap : .listenOnly,
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
        // `stop()` may have run before this queued call: don't leave a timer
        // (and a Carbon hotkey) behind a stopped monitor.
        guard tap != nil else { return }
        secureTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSecureInput() }
        }
        RunLoop.main.add(timer, forMode: .common) // keep polling while a menu is open
        secureTimer = timer
    }

    @MainActor
    private func checkSecureInput() {
        guard secureState.observe(enabled: PasteInserter.secureInputActive, at: Date()) else { return }
        if secureState.sustained {
            registerCarbon()
        } else {
            carbon = []
            Log.info("secure input off; carbon fallback removed")
        }
        onSecureInputChange?(secureState.sustained)
    }

    private func registerCarbon() {
        carbon = []
        let bindings: [(Shortcut, ShortcutBinding)] = [(shortcut, .dictate)] + (processShortcut.map { [($0, .process)] } ?? [])
        for (index, (shortcut, binding)) in bindings.enumerated() {
            if shortcut.isModifierOnly {
                // A lone modifier can't be a Carbon hotkey; its flag changes still reach the tap.
                Log.info("secure input sustained; \(shortcut.displayString) is modifier-only, no carbon fallback")
                continue
            }
            let hotkey = CarbonHotkey(shortcut: shortcut, id: UInt32(index + 1),
                                      onPress: { [weak self] in self?.carbonEvent(down: true, binding: binding) },
                                      onRelease: { [weak self] in self?.carbonEvent(down: false, binding: binding) })
            if let hotkey { carbon.append(hotkey) }
            Log.info("secure input sustained; carbon fallback \(hotkey == nil ? "could not be registered" : "registered") for \(shortcut.displayString)")
            // Only a genuine conflict is reported as one; other failures are logged above.
            if hotkey == nil, CarbonHotkey.isTakenElsewhere(shortcut) {
                let conflict = HotkeyError.shortcutInUse(shortcut.displayString)
                Task { @MainActor [weak self] in self?.onShortcutConflict?(conflict) }
            }
        }
    }

    /// Carbon events go through the same matcher so tap + Carbon can't double-fire.
    private func carbonEvent(down: Bool, binding: ShortcutBinding) {
        guard let shortcut = binding == .dictate ? self.shortcut : processShortcut else { return }
        var timing = KeyTiming(callbackNs: MonoClock.nowNs(), eventTimestamp: 0, source: .carbon)
        let (action, routed) = matcher.withLock {
            $0.handle(kind: down ? .keyDown : .keyUp, keyCode: shortcut.keyCode,
                      flags: CGEventFlags(rawValue: shortcut.modifiers), isRepeat: false)
        }
        timing.binding = routed
        if action == .press { onPress?(timing) }
        if action == .release { onRelease?(timing) }
    }

    public func stop() {
        secureTimer?.invalidate()
        secureTimer = nil
        carbon = []
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
            if let binding = matcher.withLock({ $0.reset() }) {
                var timing = now
                timing.binding = binding
                onRelease?(timing)
            }
            Log.error("hotkey tap was disabled (\(type.rawValue)); re-enabled")
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            // Utter's own ⌘V, typed text and Return: never a shortcut, and never
            // "the user pressed another key", which would cancel the dictation
            // they're typing for (typing as you speak pastes while fn is held).
            if SyntheticKeys.isOurs(event) { return Unmanaged.passUnretained(event) }
            if type == .flagsChanged { SyntheticKeys.noteRealModifierChange() }
            let kind: KeyEventKind = type == .keyDown ? .keyDown : (type == .keyUp ? .keyUp : .flagsChanged)
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let flags = event.flags
            let (action, binding) = matcher.withLock { $0.handle(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat) }
            var timing = now
            timing.binding = binding
            // Modifier changes always reach the system, or the modifier would stick.
            let consumed: Unmanaged<CGEvent>? = kind == .flagsChanged ? Unmanaged.passUnretained(event) : nil
            switch action {
            case .pass: return Unmanaged.passUnretained(event)
            case .swallow: return consumed
            case .press:
                onPress?(timing)
                return consumed
            case .release:
                onRelease?(timing)
                return consumed
            case .cancel:
                onCancel?()
                return nil
            case .abort:
                onAbort?()
                return Unmanaged.passUnretained(event)
            }
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Keystrokes Utter posts itself carry a marker, so the shortcut tap can tell
/// them from the user's keys.
public enum SyntheticKeys {
    /// Arbitrary, "UTTR" in ASCII.
    public static let marker: Int64 = 0x5554_5452

    /// A keyboard event source whose events carry the marker. Callers post
    /// with it right away, so this also marks the modifier state as stale.
    public static func source() -> CGEventSource? {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = marker
        state.withLock { $0 = true }
        return source
    }

    /// True from Utter's last posted keystroke until the next real modifier
    /// change. A posted key's flags replace the system's held-modifier state
    /// (`CGEventSource.flagsState`): after typing a phrase, a held fn read as
    /// released, and the watchdog cut the recording at every pause
    /// (evidence/m7/modifier_state_probe.log).
    public static var modifierStateIsStale: Bool { state.withLock { $0 } }

    /// The user pressed or released a modifier: the system state is real again.
    public static func noteRealModifierChange() {
        state.withLock { $0 = false }
    }

    private static let state = OSAllocatedUnfairLock(initialState: false)

    public static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
