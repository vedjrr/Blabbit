import CoreGraphics
import Foundation
import Testing
@testable import UtterKit

@Suite struct SecureInputTests {
    @Test func briefSecureInputIsNotSustained() {
        var s = SecureInputState()
        let t0 = Date()
        let c1 = s.observe(enabled: true, at: t0)
        #expect(!c1)
        let c2 = s.observe(enabled: true, at: t0.addingTimeInterval(1))
        #expect(!c2)
        #expect(!s.sustained)
        let c3 = s.observe(enabled: false, at: t0.addingTimeInterval(1.5))
        #expect(!c3)
    }

    @Test func sustainedAfterThresholdAndClearsWhenOff() {
        var s = SecureInputState()
        let t0 = Date()
        _ = s.observe(enabled: true, at: t0)
        let c4 = s.observe(enabled: true, at: t0.addingTimeInterval(SecureInputState.sustainThreshold))
        #expect(c4)
        #expect(s.sustained)
        let c5 = s.observe(enabled: true, at: t0.addingTimeInterval(10))
        #expect(!c5)
        let c6 = s.observe(enabled: false, at: t0.addingTimeInterval(11))
        #expect(c6)
        #expect(!s.sustained)
        #expect(s.enabledSince == nil)
    }

    @Test func carbonModifierMapping() {
        #expect(CarbonHotkey.carbonModifiers(Shortcut.optionSpace.modifiers) == 0x0800) // optionKey
        let all = CGEventFlags([.maskCommand, .maskAlternate, .maskControl, .maskShift]).rawValue
        #expect(CarbonHotkey.carbonModifiers(all) == 0x0100 | 0x0800 | 0x1000 | 0x0200)
    }
}
