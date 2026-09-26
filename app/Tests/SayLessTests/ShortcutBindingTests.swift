import AppKit
import os
import CoreGraphics
import Carbon
import Testing
@testable import SayLessKit

/// Hold-or-toggle, Esc cancel, the AI shortcut and modifier-only shortcuts
/// (PARITY A3, A4, A6, A7, A23).
@Suite struct ShortcutBindingTests {
    let space: UInt16 = 49
    let fn = Shortcut(keyCode: 63, modifiers: 0)
    let rightOption = Shortcut(keyCode: 61, modifiers: 0)
    let fnDown = CGEventFlags.maskSecondaryFn
    let rightOptionDown = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)

    @Test func holdOrToggleDecidesByHowLongTheKeyWasHeld() {
        let mode = DictationMode.holdOrToggle
        #expect(HotkeyPolicy.decide(keyDown: true, mode: mode, recording: false) == .start)
        // A long hold is push-to-talk: the release stops.
        #expect(HotkeyPolicy.decide(keyDown: false, mode: mode, recording: true, heldMs: 900, thresholdMs: 300) == .stop)
        #expect(HotkeyPolicy.decide(keyDown: false, mode: mode, recording: true, heldMs: 300, thresholdMs: 300) == .stop)
        // A tap latches; the next press stops.
        #expect(HotkeyPolicy.decide(keyDown: false, mode: mode, recording: true, heldMs: 120, thresholdMs: 300) == .latch)
        #expect(HotkeyPolicy.decide(keyDown: true, mode: mode, recording: true) == .stop)
        // The stopping press's own key-up does nothing.
        #expect(HotkeyPolicy.decide(keyDown: false, mode: mode, recording: false, heldMs: 50) == .ignore)
        // The threshold is honoured.
        #expect(HotkeyPolicy.decide(keyDown: false, mode: mode, recording: true, heldMs: 450, thresholdMs: 500) == .latch)
    }

    @Test func holdThresholdPersistsWithinItsRange() throws {
        let suite = "dev.sayless.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DictationMode.holdThresholdMs(from: defaults) == 300)
        defaults.set(650, forKey: DictationMode.holdThresholdKey)
        #expect(DictationMode.holdThresholdMs(from: defaults) == 650)
        defaults.set(99_999, forKey: DictationMode.holdThresholdKey)
        #expect(DictationMode.holdThresholdMs(from: defaults) == 1000)
        DictationMode.holdOrToggle.save(to: defaults)
        #expect(DictationMode.load(from: defaults) == .holdOrToggle)
    }

    @Test func aLatchedTapIsNotCutByTheKeyWatchdog() {
        // After a tap the controller treats the recording as a toggle one.
        var checks = 0
        for _ in 0..<4 {
            #expect(WatchdogPolicy.releaseReason(elapsed: 3, maxSeconds: 600, source: .toggle, keyDown: false, secureInput: false, keyUpChecks: &checks) == nil)
        }
    }

    // MARK: Esc cancel

    @Test func escCancelsOnlyWhileArmedAndIsSwallowedBothWays() {
        var router = HotkeyRouter(primary: .optionSpace)
        // Not recording: Esc belongs to the focused app.
        #expect(router.handle(kind: .keyDown, keyCode: 53, flags: [], isRepeat: false).0 == .pass)
        #expect(router.handle(kind: .keyUp, keyCode: 53, flags: [], isRepeat: false).0 == .pass)
        router.cancelArmed = true
        #expect(router.handle(kind: .keyDown, keyCode: 53, flags: [], isRepeat: false).0 == .cancel)
        #expect(router.handle(kind: .keyDown, keyCode: 53, flags: [], isRepeat: true).0 == .swallow)
        router.cancelArmed = false // the dictation ended; its Esc key-up is still ours
        #expect(router.handle(kind: .keyUp, keyCode: 53, flags: [], isRepeat: false).0 == .swallow)
        #expect(router.handle(kind: .keyUp, keyCode: 53, flags: [], isRepeat: false).0 == .pass)
    }

    @Test func escWithModifiersIsLeftAlone() {
        var router = HotkeyRouter(primary: .optionSpace)
        router.cancelArmed = true
        #expect(router.handle(kind: .keyDown, keyCode: 53, flags: .maskCommand, isRepeat: false).0 == .pass) // ⌘Esc
        #expect(router.handle(kind: .keyDown, keyCode: 53, flags: [.maskAlphaShift], isRepeat: false).0 == .cancel) // caps lock is fine
    }

    // MARK: AI shortcut

    @Test func theSecondShortcutIsRoutedToItsBinding() {
        let ai = Shortcut(keyCode: 49, modifiers: CGEventFlags([.maskAlternate, .maskShift]).rawValue) // ⌥⇧Space
        var router = HotkeyRouter(primary: .optionSpace, secondary: ai)
        let press = router.handle(kind: .keyDown, keyCode: space, flags: [.maskAlternate, .maskShift], isRepeat: false)
        #expect(press.0 == .press && press.1 == .process)
        let release = router.handle(kind: .keyUp, keyCode: space, flags: [.maskAlternate, .maskShift], isRepeat: false)
        #expect(release.0 == .release && release.1 == .process)
        let plain = router.handle(kind: .keyDown, keyCode: space, flags: .maskAlternate, isRepeat: false)
        #expect(plain.0 == .press && plain.1 == .dictate)
        #expect(router.reset() == .dictate)
        #expect(router.reset() == nil)
        // No second shortcut: its keys pass through.
        var single = HotkeyRouter(primary: .optionSpace)
        #expect(single.handle(kind: .keyDown, keyCode: space, flags: [.maskAlternate, .maskShift], isRepeat: false).0 == .pass)
    }

    @MainActor @Test func theTwoShortcutsMustDiffer() {
        let model = ShortcutRecorderModel(current: nil, other: .optionSpace, title: "AI Shortcut")
        model.record(keyCode: 49, modifierFlags: [.option])
        #expect(model.problem?.contains("other Say Less shortcut") == true && !model.canSave)
        model.record(keyCode: 2, modifierFlags: [.control, .option])
        #expect(model.problem == nil && model.canSave)
    }

    @MainActor @Test func processModeIsAlwaysAnAIMode() {
        let controller = DictationController(models: ModelManager())
        let saved = UserDefaults.standard.string(forKey: DictationController.processModeKey)
        defer { UserDefaults.standard.set(saved, forKey: DictationController.processModeKey) }
        controller.processMode = .custom
        #expect(controller.processMode == .custom)
        controller.processMode = .exact // not an AI mode: refused
        #expect(controller.processMode == .custom)
        UserDefaults.standard.set("clean", forKey: DictationController.processModeKey)
        #expect(controller.processMode == .professional)
    }

    // MARK: Modifier-only (fn, right-side modifiers)

    @Test func fnAloneIsAPushToTalkKey() {
        var m = ShortcutMatcher(shortcut: fn)
        #expect(m.handle(kind: .flagsChanged, keyCode: 63, flags: fnDown, isRepeat: false) == .press)
        #expect(m.isHeld)
        #expect(m.handle(kind: .flagsChanged, keyCode: 63, flags: [], isRepeat: false) == .release)
        #expect(!m.isHeld)
    }

    @Test func aKeyPressedWhileTheModifierIsHeldAbortsIt() {
        var m = ShortcutMatcher(shortcut: fn)
        _ = m.handle(kind: .flagsChanged, keyCode: 63, flags: fnDown, isRepeat: false)
        // fn + ← is Home: the user was typing a combo.
        #expect(m.handle(kind: .keyDown, keyCode: 123, flags: fnDown, isRepeat: false) == .abort)
        #expect(!m.isHeld)
        #expect(m.handle(kind: .flagsChanged, keyCode: 63, flags: [], isRepeat: false) == .pass)
        // Arrow keys carry the fn flag without a flagsChanged: never a press.
        #expect(m.handle(kind: .keyDown, keyCode: 123, flags: fnDown, isRepeat: false) == .pass)
    }

    @Test func rightOptionIsNotLeftOptionAndNotACombo() {
        var m = ShortcutMatcher(shortcut: rightOption)
        // Left ⌥ (58) sets ⌥ but not the right-hand device bit.
        #expect(m.handle(kind: .flagsChanged, keyCode: 58, flags: .maskAlternate, isRepeat: false) == .pass)
        // ⌘ already held, then right ⌥: a combo, not ours.
        #expect(m.handle(kind: .flagsChanged, keyCode: 61, flags: [rightOptionDown, .maskCommand], isRepeat: false) == .pass)
        #expect(!m.isHeld)
        #expect(m.handle(kind: .flagsChanged, keyCode: 61, flags: rightOptionDown, isRepeat: false) == .press)
        // Right ⌥ + Space types a character in some layouts: combo → abort.
        #expect(m.handle(kind: .keyDown, keyCode: space, flags: rightOptionDown, isRepeat: false) == .abort)
    }

    @Test func modifierOnlyShortcutsAreValidatedAndNamed() {
        #expect(fn.isModifierOnly && fn.problem == nil)
        #expect(fn.displayString == "fn")
        #expect(rightOption.displayString == "Right ⌥")
        #expect(Shortcut(keyCode: 63, modifiers: CGEventFlags.maskCommand.rawValue).problem != nil)
        #expect(!Shortcut.optionSpace.isModifierOnly)
        #expect(!CarbonHotkey.isTakenElsewhere(fn))
    }

    @MainActor @Test func theRecorderCapturesALoneModifier() {
        let model = ShortcutRecorderModel(current: .optionSpace)
        // Press and release fn with nothing else.
        model.recordFlagsChanged(keyCode: 63, rawFlags: fnDown.rawValue)
        model.recordFlagsChanged(keyCode: 63, rawFlags: 0)
        #expect(model.candidate == fn && model.canSave)
        #expect(model.note?.contains("Do Nothing") == true)
        // Right ⌥ pressed, then a key: an ordinary combo is recorded instead.
        let other = ShortcutRecorderModel(current: .optionSpace)
        other.recordFlagsChanged(keyCode: 61, rawFlags: rightOptionDown.rawValue)
        other.record(keyCode: 2, modifierFlags: [.option, .control])
        other.recordFlagsChanged(keyCode: 61, rawFlags: 0)
        #expect(other.candidate?.keyCode == 2)
        // Left ⌥ alone is never a shortcut.
        let left = ShortcutRecorderModel(current: .optionSpace)
        left.recordFlagsChanged(keyCode: 58, rawFlags: CGEventFlags.maskAlternate.rawValue)
        left.recordFlagsChanged(keyCode: 58, rawFlags: 0)
        #expect(left.candidate == nil)
    }
}

/// The bug a human found: holding the shortcut in Hold to Talk was cut after
/// 0.5 s, because the watchdog read the session key state, which never sees a
/// key the tap swallows. Real tap, real HID-level key events (F13, harmless).
@Suite(.serialized, .enabled(if: AXIsProcessTrusted(), "test runner is not trusted for Accessibility"),
       .enabled(if: !IsSecureEventInputEnabled(), "secure input is on (a password field or Secure Keyboard Entry): event taps see no keys"))
struct HeldShortcutTests {
    @Test func aHeldShortcutReadsAsDownWhileTheTapSwallowsIt() throws {
        let f13 = Shortcut(keyCode: 105, modifiers: 0)
        let monitor = HotkeyMonitor(shortcut: f13)
        let presses = OSAllocatedUnfairLock(initialState: (down: 0, up: 0))
        monitor.onPress = { _ in presses.withLock { $0.down += 1 } }
        monitor.onRelease = { _ in presses.withLock { $0.up += 1 } }
        try monitor.start()
        defer { monitor.stop() }
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 105, keyDown: true)?.post(tap: .cghidEventTap)
        defer { CGEvent(keyboardEventSource: source, virtualKey: 105, keyDown: false)?.post(tap: .cghidEventTap) }
        // Longer than the watchdog's two 250 ms checks.
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.2)
            #expect(f13.isPhysicallyDown(), "held key read as up")
        }
        // The same checks the watchdog runs, with the live key state.
        var checks = 0
        #expect(WatchdogPolicy.releaseReason(elapsed: 1.2, maxSeconds: 600, source: .tap, keyDown: f13.isPhysicallyDown(),
                                             secureInput: false, keyUpChecks: &checks) == nil)
        CGEvent(keyboardEventSource: source, virtualKey: 105, keyDown: false)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!f13.isPhysicallyDown())
        #expect(presses.withLock { $0 } == (down: 1, up: 1), "the tap saw one press and one release")
    }

    /// Human-found (2026-09-26): typing as you speak pastes with ⌘V while a
    /// modifier-only shortcut is held, and the tap took that for the user
    /// typing a combo, cancelling the dictation. Say Less's own keys must pass;
    /// a real other key must still abort. Right ⌘ as the shortcut, F16 as the
    /// key (it does nothing), through the real tap.
    @Test func saylessOwnKeystrokesDontAbortAHeldModifierShortcut() throws {
        let rightCommand = Shortcut(keyCode: 54, modifiers: 0)
        let monitor = HotkeyMonitor(shortcut: rightCommand)
        let seen = OSAllocatedUnfairLock(initialState: (press: 0, abort: 0))
        monitor.onPress = { _ in seen.withLock { $0.press += 1 } }
        monitor.onAbort = { seen.withLock { $0.abort += 1 } }
        try monitor.start()
        defer { monitor.stop() }
        let user = CGEventSource(stateID: .hidSystemState)
        func post(_ source: CGEventSource?, _ key: CGKeyCode, _ down: Bool, flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            if key == 54 { event?.type = .flagsChanged }
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.1)
        }
        let held = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        post(user, 54, true, flags: held)
        defer { post(user, 54, false, flags: []) }
        #expect(seen.withLock { $0.press } == 1)
        post(SyntheticKeys.source(), 106, true, flags: [])
        post(SyntheticKeys.source(), 106, false, flags: [])
        #expect(seen.withLock { $0.abort } == 0, "Say Less's own keystroke aborted the dictation")
        post(user, 106, true, flags: held)
        post(user, 106, false, flags: held)
        #expect(seen.withLock { $0.abort } == 1, "a real combo still aborts")
    }

    @Test func syntheticKeysAreMarked() throws {
        let ours = try #require(CGEvent(keyboardEventSource: SyntheticKeys.source(), virtualKey: 9, keyDown: true))
        let theirs = try #require(CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 9, keyDown: true))
        #expect(SyntheticKeys.isOurs(ours))
        #expect(!SyntheticKeys.isOurs(theirs))
    }

    /// Say Less's own ⌘V wipes a held fn from the system's modifier state; the
    /// watchdog must not read that as the user letting go (it cut every
    /// typing-as-you-speak recording at the first pause).
    @Test func aHeldModifierShortcutSurvivesSayLessTypingAPhrase() throws {
        let fn = Shortcut(keyCode: 63, modifiers: 0)
        let key = Shortcut(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue) // ⌥Space
        _ = try #require(SyntheticKeys.source()) // what every paste and typed key does first
        #expect(SyntheticKeys.modifierStateIsStale)
        #expect(fn.isPhysicallyDown(), "stale state: trust the tap, which sees the real release")
        #expect(!key.isPhysicallyDown(), "a key shortcut reads its own key, which posting doesn't touch")
        SyntheticKeys.noteRealModifierChange()
        #expect(!SyntheticKeys.modifierStateIsStale)
        #expect(!fn.isPhysicallyDown(), "real state again: fn isn't held during tests")
    }
}
