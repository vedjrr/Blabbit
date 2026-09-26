import Foundation
import Testing
import SayLessCore
@testable import SayLessKit

/// End-to-end through the UniFFI bridge with the real Parakeet V3 model (`make models`).
@Suite(.serialized) struct EngineBridgeTests {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func loadFixture(_ name: String) throws -> (samples: [Float], reference: String) {
        let wav = Self.repoRoot.appendingPathComponent("fixtures/audio/\(name).wav")
        let data = try Data(contentsOf: wav)
        // Fixtures are canonical 44-byte-header PCM16 mono 16 kHz WAVs (scripts/make-tts-fixtures.sh).
        let pcm = data.dropFirst(44)
        let samples = stride(from: pcm.startIndex, to: pcm.endIndex - 1, by: 2).map { i -> Float in
            Float(Int16(bitPattern: UInt16(pcm[i]) | UInt16(pcm[i + 1]) << 8)) / 32768
        }
        let reference = try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        return (samples, reference)
    }

    @Test func transcribesFixtureThroughBridgeAndLoadsOnce() throws {
        let modelPath = ModelLocation.defaultModelURL.path
        try #require(FileManager.default.fileExists(atPath: modelPath), "run `make models` first")
        let engine = SayLessEngine()
        let info = try engine.loadModel(path: modelPath)
        #expect(info.loadMs > 0)
        let (samples, reference) = try loadFixture("tts_02")
        for _ in 0..<3 {
            let result = try engine.transcribe(pcm: samples, options: DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: false))
            #expect(result.skipped == nil)
            #expect(wordErrorRate(reference: reference, hypothesis: result.text) == 0)
        }
        #expect(engine.loadCount() == 1)
        #expect(engine.modelInfo()?.architecture == "parakeet")
    }

    /// Settings → Audio → Remove long silences reaches the Rust VAD (PARITY A16).
    @Test func silenceTrimmingRunsThroughTheBridge() throws {
        let modelPath = ModelLocation.defaultModelURL.path
        try #require(FileManager.default.fileExists(atPath: modelPath), "run `make models` first")
        let engine = SayLessEngine()
        _ = try engine.loadModel(path: modelPath)
        let (samples, reference) = try loadFixture("tts_03")
        let pause = [Float](repeating: 0, count: 16_000 * 4)
        let padded = pause + samples + pause
        let trimmed = try engine.transcribe(pcm: padded, options: DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: true))
        #expect(trimmed.trimmedMs > 6_000, "removed \(trimmed.trimmedMs) ms of 8 s")
        #expect(trimmed.audioMs == UInt64(padded.count / 16))
        #expect(wordErrorRate(reference: reference, hypothesis: trimmed.text) == 0, "\(trimmed.text)")
        let untouched = try engine.transcribe(pcm: padded, options: DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: false))
        #expect(untouched.trimmedMs == 0)
    }

    @Test func tooShortAndSilentAreSkipped() throws {
        let engine = SayLessEngine()
        let short = try engine.transcribe(pcm: [Float](repeating: 0.3, count: 3_000), options: DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: false))
        #expect(short.skipped == .tooShort)
        let silent = try engine.transcribe(pcm: [Float](repeating: 0, count: 32_000), options: DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: false))
        #expect(silent.skipped == .silent)
        #expect(silent.text.isEmpty)
    }

    /// ADR-003 budget: handing 5 min of PCM to Rust must be cheap. Silent audio is
    /// rejected by the Rust skip check, so this times the FFI copy + one scan.
    @Test func fiveMinuteBufferCrossesTheBridgeQuickly() throws {
        let engine = SayLessEngine()
        let fiveMinutes = [Float](repeating: 0, count: 16_000 * 300)
        var best = Double.infinity
        for _ in 0..<5 {
            let t0 = MonoClock.nowNs()
            let r = try engine.transcribe(pcm: fiveMinutes, options: DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: false))
            best = min(best, MonoClock.ms(from: t0, to: MonoClock.nowNs()))
            #expect(r.skipped == .silent)
        }
        print("ffi_5min_roundtrip_best_ms=\(String(format: "%.2f", best))")
        #expect(best < 50)
    }

    @Test func errorsArePlainEnglishNotDebugDumps() {
        let engine = SayLessEngine()
        do {
            _ = try engine.loadModel(path: "/nonexistent/model.gguf")
            Issue.record("expected an error")
        } catch let error as CoreError {
            #expect(error.userMessage == "The speech model file could not be found. Download it again from the Model Manager.")
            #expect(!error.userMessage.contains("CoreError"))
            #expect(error.logDetail.contains("/nonexistent/model.gguf"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }
}
