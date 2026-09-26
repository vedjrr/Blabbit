import AppKit
import Testing
@testable import SayLessKit

@Suite struct HotkeyModeTests {
    @Test func pushToTalkAndToggleDecisions() {
        // Hold to talk: press starts, release stops; repeats and stray releases do nothing.
        #expect(HotkeyPolicy.decide(keyDown: true, mode: .pushToTalk, recording: false) == .start)
        #expect(HotkeyPolicy.decide(keyDown: false, mode: .pushToTalk, recording: true) == .stop)
        #expect(HotkeyPolicy.decide(keyDown: true, mode: .pushToTalk, recording: true) == .ignore)
        #expect(HotkeyPolicy.decide(keyDown: false, mode: .pushToTalk, recording: false) == .ignore)
        // Toggle: each press flips; releases are ignored.
        #expect(HotkeyPolicy.decide(keyDown: true, mode: .toggle, recording: false) == .start)
        #expect(HotkeyPolicy.decide(keyDown: false, mode: .toggle, recording: true) == .ignore)
        #expect(HotkeyPolicy.decide(keyDown: true, mode: .toggle, recording: true) == .stop)
    }

    @Test func eventTimestampsMapOntoOurClock() {
        let callback = MonoClock.nowNs()
        #expect(MonoClock.eventNs(0, before: callback) == nil)                         // synthetic events
        #expect(MonoClock.eventNs(callback - 2_000_000, before: callback) == callback - 2_000_000) // already ns
        #expect(MonoClock.eventNs(callback + 5, before: callback) == nil)              // from the future
        // Mach ticks (24 MHz on Apple silicon): converted onto the ns clock.
        let (numer, denom) = MonoClock.timebase
        let ticks = (callback - 3_000_000) / numer * denom
        let mapped = MonoClock.eventNs(ticks, before: callback)
        if numer != denom {
            #expect(mapped != nil && callback - mapped! < 3_100_000 && callback - mapped! >= 2_900_000, "mapped \(String(describing: mapped))")
        }
    }

    @Test func toggleRecordingsAreNotCutByTheKeyWatchdog() {
        var checks = 0
        for _ in 0..<5 {
            #expect(WatchdogPolicy.releaseReason(elapsed: 5, maxSeconds: 600, source: .toggle, keyDown: false, secureInput: true, keyUpChecks: &checks) == nil)
        }
        #expect(WatchdogPolicy.releaseReason(elapsed: 600, maxSeconds: 600, source: .toggle, keyDown: false, secureInput: false, keyUpChecks: &checks) == "max_length")
    }

    @Test func modeAndShortcutPersist() throws {
        let suite = "dev.sayless.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DictationMode.load(from: defaults) == .pushToTalk)
        DictationMode.toggle.save(to: defaults)
        #expect(DictationMode.load(from: defaults) == .toggle)

        #expect(Shortcut.load(from: defaults) == .optionSpace)
        let custom = Shortcut(keyCode: 2, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue) // ⌃⌥D
        custom.save(to: defaults)
        #expect(Shortcut.load(from: defaults) == custom)
        // A stored shortcut that became invalid falls back to the default.
        Shortcut(keyCode: 12, modifiers: CGEventFlags.maskCommand.rawValue).save(to: defaults) // ⌘Q
        #expect(Shortcut.load(from: defaults) == .optionSpace)
    }

    @Test func unsafeShortcutsAreRejected() {
        #expect(Shortcut.optionSpace.problem == nil)
        #expect(Shortcut(keyCode: 96, modifiers: 0).problem == nil)                                          // F5 alone
        #expect(Shortcut(keyCode: 2, modifiers: 0).problem != nil)                                           // D alone
        #expect(Shortcut(keyCode: 2, modifiers: CGEventFlags.maskShift.rawValue).problem != nil)             // ⇧D
        #expect(Shortcut(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue).problem != nil)          // ⌘Space (Spotlight)
        #expect(Shortcut(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue).problem != nil)           // ⌘V
        #expect(Shortcut(keyCode: 53, modifiers: CGEventFlags.maskAlternate.rawValue).problem != nil)        // ⌥Esc
        #expect(Shortcut(keyCode: 2, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue).problem == nil)
    }

    @MainActor @Test func shortcutNamesUseTheKeyboardLayout() async {
        #expect(Shortcut.optionSpace.displayString == "⌥Space")
        #expect(Shortcut(keyCode: 96, modifiers: 0).displayString == "F5")
        let d = Shortcut(keyCode: 2, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue).displayString
        #expect(d.hasPrefix("⌃⌥") && d.count == 3 && !d.contains("Key"), "got \(d)")
        // Off the main thread (e.g. logging from the event tap): the cached name, no TIS call.
        let offMain = await Task.detached { Shortcut(keyCode: 2, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue).displayString }.value
        #expect(offMain == d)
    }

    @MainActor @Test func recorderAcceptsValidAndExplainsInvalid() {
        let model = ShortcutRecorderModel(current: .optionSpace)
        #expect(!model.canSave)
        model.record(keyCode: 2, modifierFlags: [.control, .option])
        #expect(model.problem == nil && model.canSave)
        model.record(keyCode: 49, modifierFlags: [.command])
        #expect(model.problem?.contains("already used") == true && !model.canSave)
        model.record(keyCode: 49, modifierFlags: [.option]) // the current one: nothing to save
        #expect(!model.canSave)
    }
}
