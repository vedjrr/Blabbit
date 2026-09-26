import CoreGraphics
import Testing
@testable import BlabbitKit

@Suite struct ShortcutMatcherTests {
    let space: UInt16 = 49

    @Test func pushToTalkPressAndReleaseAreSwallowed() {
        var m = ShortcutMatcher(shortcut: .optionSpace)
        #expect(m.handle(kind: .keyDown, keyCode: space, flags: .maskAlternate, isRepeat: false) == .press)
        #expect(m.isHeld)
        #expect(m.handle(kind: .keyDown, keyCode: space, flags: .maskAlternate, isRepeat: true) == .swallow)
        #expect(m.handle(kind: .keyUp, keyCode: space, flags: .maskAlternate, isRepeat: false) == .release)
        #expect(!m.isHeld)
    }

    @Test func plainSpaceAndOtherCombosPassThrough() {
        var m = ShortcutMatcher(shortcut: .optionSpace)
        #expect(m.handle(kind: .keyDown, keyCode: space, flags: [], isRepeat: false) == .pass)
        #expect(m.handle(kind: .keyDown, keyCode: space, flags: [.maskAlternate, .maskCommand], isRepeat: false) == .pass)
        #expect(m.handle(kind: .keyDown, keyCode: 0, flags: .maskAlternate, isRepeat: false) == .pass)
        #expect(m.handle(kind: .keyUp, keyCode: space, flags: [], isRepeat: false) == .pass)
        #expect(m.handle(kind: .flagsChanged, keyCode: 58, flags: .maskAlternate, isRepeat: false) == .pass)
    }

    @Test func releasingModifierFirstStillEndsOnKeyUp() {
        var m = ShortcutMatcher(shortcut: .optionSpace)
        _ = m.handle(kind: .keyDown, keyCode: space, flags: .maskAlternate, isRepeat: false)
        #expect(m.handle(kind: .flagsChanged, keyCode: 58, flags: [], isRepeat: false) == .pass)
        #expect(m.handle(kind: .keyUp, keyCode: space, flags: [], isRepeat: false) == .release)
    }

    @Test func capsLockAndFnDoNotBreakMatching() {
        var m = ShortcutMatcher(shortcut: .optionSpace)
        #expect(m.handle(kind: .keyDown, keyCode: space, flags: [.maskAlternate, .maskAlphaShift, .maskSecondaryFn], isRepeat: false) == .press)
    }

    @Test func autoRepeatWithoutPressIsIgnored() {
        var m = ShortcutMatcher(shortcut: .optionSpace)
        #expect(m.handle(kind: .keyDown, keyCode: space, flags: .maskAlternate, isRepeat: true) == .pass)
    }

    @Test func resetReportsWhetherKeyWasHeld() {
        var m = ShortcutMatcher(shortcut: .optionSpace)
        #expect(m.reset() == false)
        _ = m.handle(kind: .keyDown, keyCode: space, flags: .maskAlternate, isRepeat: false)
        #expect(m.reset() == true)
        #expect(!m.isHeld)
    }

    @Test func displayString() {
        #expect(Shortcut.optionSpace.displayString == "⌥Space")
    }
}
