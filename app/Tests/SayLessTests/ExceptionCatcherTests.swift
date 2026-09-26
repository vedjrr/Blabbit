import Foundation
import Testing
import SayLessObjC
@testable import SayLessKit

/// AVAudioEngine reports some failures (a format mismatch right after a device
/// change) as Objective-C exceptions, which crash a Swift app unless caught.
@Suite struct ExceptionCatcherTests {
    @Test func anObjectiveCExceptionBecomesAReason() {
        let reason = SayLessCatchException {
            NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                        reason: "Input HW format and tap format not matching", userInfo: nil).raise()
        }
        #expect(reason == "com.apple.coreaudio.avfaudio: Input HW format and tap format not matching")
    }

    @Test func aNormalBlockReturnsNil() {
        var ran = false
        #expect(SayLessCatchException { ran = true } == nil)
        #expect(ran)
    }

    @Test func deviceChangingHasAPlainMessage() {
        #expect(AudioRecorderError.deviceChanging("x").userMessage == "The microphone is changing. Try again in a moment.")
    }
}
