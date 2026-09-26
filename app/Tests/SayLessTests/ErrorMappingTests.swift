import CoreGraphics
import Foundation
import Testing
import SayLessCore
@testable import SayLessKit

/// G5: every failure in BRIEF §16 has a plain-English message.
@Suite struct ErrorMappingTests {
    /// Signs of a developer message leaking to users.
    static let jargon = ["Error", "error:", "nil", "Optional(", "0x", "Domain=", "{", "}", "(null)", "exception", "panic", "unwrap",
                         "Code=", "NSError", "errno", "stack", "assert"]

    static func isPlainEnglish(_ message: String) -> Bool {
        guard let first = message.first, first.isUppercase, message.count < 260,
              let last = message.last, ".:!".contains(last) else { return false }
        return !jargon.contains { message.contains($0) }
    }

    @Test(arguments: Failure.allCases)
    func everyFailureHasAPlainMessage(failure: Failure) {
        #expect(Self.isPlainEnglish(failure.message), "\(failure): \(failure.message)")
    }

    /// The insertion failure message as actually shown: the prefix plus each reason the inserter gives.
    @Test func composedInsertionFailuresArePlain() {
        let reasons = ["No insertion method worked for this app.", "The insertion script is missing or not executable. Check Settings → Text Insertion.",
                       "The insertion script took longer than 5 seconds and was stopped.", "The insertion script failed (exit code 2)."]
        for why in reasons {
            let shown = InsertionOutcome.plan(for: InsertReport(result: .failed(why), bundleID: nil)).failure ?? ""
            #expect(shown.hasPrefix(SecureInputFallback.failedMessagePrefix))
            #expect(Self.isPlainEnglish(shown), "\(shown)")
        }
    }

    @Test func coversEveryFailureTheBriefNames() {
        // BRIEF §16, in order.
        let brief: [Failure] = [.microphonePermissionDenied, .accessibilityPermissionDenied, .modelMissing, .modelDownloadFailure,
                                .corruptedModel, .insufficientMemory, .unsupportedModel, .inferenceFailure, .microphoneDisconnected,
                                .hotkeyConflict, .textInsertionFailure, .unavailableFocusedApplication]
        #expect(Set(brief) == Set(Failure.allCases))
    }

    @Test func everyCoreErrorKindIsPlain() {
        let messages = errorMessages()
        #expect(messages.count >= 11)
        for m in messages { #expect(Self.isPlainEnglish(m.message), "\(m.kind): \(m.message)") }
    }

    /// The runtime's "unsupported language" is its own plain message, not "model not supported".
    @Test func unsupportedLanguageHasItsOwnMessage() throws {
        let model = ModelLocation.modelsDirectory.appendingPathComponent("moonshine-base/moonshine-base-Q8_0.gguf").path
        try #require(FileManager.default.fileExists(atPath: model), "run `make models` first")
        let engine = SayLessEngine()
        _ = try engine.loadModel(path: model)
        // Real speech: a tone would now be skipped as "no speech" before the model runs.
        let speech = try EngineBridgeTests().loadFixture("tts_01").samples
        do {
            _ = try engine.transcribe(pcm: speech, options: DictationOptions(language: "de", translate: false, initialPrompt: nil, trimSilence: false))
            Issue.record("Moonshine (English only) must refuse German")
        } catch let error as CoreError {
            guard case .LanguageUnsupported = error else { Issue.record("got \(error.logDetail)"); return }
            #expect(Self.isPlainEnglish(error.userMessage) && error.userMessage.contains("language"))
        }
    }

    /// Real failures from the Rust core carry exactly the catalogued text.
    @Test func realCoreFailuresMapToTheirMessages() throws {
        let engine = SayLessEngine()
        do {
            _ = try engine.transcribe(pcm: [Float](repeating: 0.1, count: 16_000), options: DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: false))
            Issue.record("transcribing without a model must fail")
        } catch let error as CoreError {
            #expect(Self.isPlainEnglish(error.userMessage) && error.userMessage == errorMessages().first { $0.kind == "ModelNotLoaded" }?.message)
        }
        do {
            _ = try engine.loadModel(path: "/nonexistent/model.gguf")
            Issue.record("a missing file must fail")
        } catch let error as CoreError {
            #expect(error.userMessage == Failure.modelMissing.message)
        }
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("sayless-garbage-\(UUID().uuidString).gguf")
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        do {
            _ = try engine.loadModel(path: garbage.path)
            Issue.record("a corrupt file must fail")
        } catch let error as CoreError {
            #expect([Failure.corruptedModel.message, Failure.unsupportedModel.message].contains(error.userMessage), "\(error.userMessage)")
        }
    }

    @MainActor @Test func shortcutTakenByAnotherRegistrationIsDetected() throws {
        // ⌃⌥⇧F13: unlikely to be used by anything on the test Mac.
        let shortcut = Shortcut(keyCode: 105, modifiers: CGEventFlags([.maskControl, .maskAlternate, .maskShift]).rawValue)
        #expect(!CarbonHotkey.isTakenElsewhere(shortcut))
        let holder = try #require(CarbonHotkey(shortcut: shortcut, onPress: {}, onRelease: {}))
        #expect(CarbonHotkey.isTakenElsewhere(shortcut), "a registered hotkey is reported as taken")
        _ = holder
        let recorder = ShortcutRecorderModel(current: .optionSpace)
        recorder.record(keyCode: 105, modifierFlags: [.control, .option, .shift])
        #expect(recorder.problem == HotkeyError.shortcutInUse(shortcut.displayString).userMessage && !recorder.canSave)
    }
}
