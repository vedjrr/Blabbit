import AVFoundation
import Darwin
import Testing
@testable import UtterKit

@Suite struct ClockTests {
    @Test func hostTimeConversionMatchesAVAudioTimeAndUptimeClock() {
        let ticks = mach_absolute_time()
        let ours = MonoClock.ns(fromHostTime: ticks)
        let apple = UInt64(AVAudioTime.seconds(forHostTime: ticks) * 1_000_000_000)
        #expect(ours > apple ? ours - apple < 1_000 : apple - ours < 1_000)
        let now = MonoClock.nowNs()
        #expect(now >= ours && now - ours < 50_000_000)
    }

    @Test func conversionDoesNotOverflowForLongUptimes() {
        let thirtyDaysOfTicks: UInt64 = 30 * 24 * 3600 * 24_000_000
        let ns = MonoClock.ns(fromHostTime: thirtyDaysOfTicks)
        #expect(ns / 1_000_000_000 / 3600 / 24 >= 29)
    }
}
