import Foundation
import Testing
import UtterCore
@testable import UtterKit

/// Long dictations are transcribed in segments while recording (real model).
@Suite(.serialized) struct IncrementalTranscriberTests {
    static let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/audio")

    /// Fixture sentences with 0.8 s pauses; `noise` adds room noise everywhere
    /// (so pauses aren't digital zero).
    static func dictation(seconds: Double, noise: Float = 0) throws -> (audio: [Float], reference: String) {
        let wavs = try FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
        var audio: [Float] = []
        var reference = ""
        var index = 0
        // Whole sentences until `seconds` is reached (not a full pass of every clip).
        while Double(audio.count) < seconds * 16_000 {
            let wav = wavs[index % wavs.count]
            index += 1
            audio += try loadWav16kMono(path: wav.path)
            audio += [Float](repeating: 0, count: 12_800)
            reference += (try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) + " "
        }
        if noise > 0 {
            var seed: UInt32 = 12345
            for i in audio.indices {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                audio[i] += (Float(seed >> 8) / Float(1 << 24) - 0.5) * 2 * noise
            }
        }
        return (audio, reference)
    }

    static func engine(_ file: String = "parakeet-tdt-0.6b-v3/parakeet-tdt-0.6b-v3-Q8_0.gguf") throws -> UtterEngine {
        let model = ModelLocation.modelsDirectory.appendingPathComponent(file).path
        try #require(FileManager.default.fileExists(atPath: model), "run `make models` first")
        let engine = UtterEngine()
        _ = try engine.loadModel(path: model)
        return engine
    }

    static let options = DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: false)

    @Test(arguments: [Float(0), 0.003]) // digital silence, and room noise at about -50 dBFS
    func segmentsWhileRecordingAndLeavesOnlyTheTail(noise: Float) async throws {
        let engine = try Self.engine()
        let (audio, reference) = try Self.dictation(seconds: 45, noise: noise)
        let inc = IncrementalTranscriber(engine: engine, options: Self.options)
        var fed = 0
        while fed < audio.count {
            let next = min(fed + 32_000, audio.count)
            inc.append(Array(audio[fed..<next]))
            fed = next
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(inc.fed == audio.count)
        let result = try await inc.finish(complete: audio)
        let oneShot = try engine.transcribe(pcm: audio, options: Self.options)
        #expect(result.segments >= 2, "segments \(result.segments)")
        #expect(result.tailInferenceMs * 2 < oneShot.inferenceMs, "tail \(result.tailInferenceMs) ms vs one-shot \(oneShot.inferenceMs) ms")
        // No accuracy lost against what was said (one-shot degrades on long audio).
        let segmented = wordErrorRate(reference: reference, hypothesis: result.text)
        let whole = wordErrorRate(reference: reference, hypothesis: oneShot.text)
        #expect(segmented <= whole + 0.02, "segmented \(segmented) vs one-shot \(whole)")
    }

    /// Releasing while the first segment is still running must not be slower
    /// than transcribing everything at once (the controller routes to `finish`).
    @Test func releaseDuringARunningSegmentIsNoSlowerThanOneShot() async throws {
        let engine = try Self.engine()
        let (audio, _) = try Self.dictation(seconds: 25)
        let oneShotStart = MonoClock.nowNs()
        _ = try engine.transcribe(pcm: audio, options: Self.options)
        let oneShotMs = MonoClock.ms(from: oneShotStart, to: MonoClock.nowNs())
        let inc = IncrementalTranscriber(engine: engine, options: Self.options)
        inc.append(audio) // a pause ≥ 10 s in: the first segment starts now
        #expect(inc.hasStarted)
        let released = MonoClock.nowNs()
        let result = try await inc.finish(complete: audio)
        let releaseMs = MonoClock.ms(from: released, to: MonoClock.nowNs())
        #expect(releaseMs <= oneShotMs * 1.1 + 30, "release \(releaseMs) ms vs one-shot \(oneShotMs) ms")
        #expect(!result.text.isEmpty)
    }

    static let whisperMedium = "whisper-medium/whisper-medium-Q8_0.gguf"

    /// Whisper pads each call to 30 s: under 30 s of recording nothing is
    /// segmented, so release costs exactly one-shot.
    @Test func whisperNeverSegmentsUnderOneWindow() async throws {
        let engine = try Self.engine(Self.whisperMedium)
        let (audio, _) = try Self.dictation(seconds: 25)
        #expect(Double(audio.count) / 16_000 < 30)
        let inc = IncrementalTranscriber(engine: engine, options: Self.options, policy: .forModelFamily("whisper"))
        var fed = 0
        while fed < audio.count {
            let next = min(fed + 32_000, audio.count)
            inc.append(Array(audio[fed..<next]))
            fed = next
        }
        #expect(!inc.hasStarted, "a segment + tail would cost two windows where one-shot costs one")
    }

    /// The worst case on a slow model: release right after a segment starts.
    @Test func whisperReleaseRightAfterASegmentStartsIsNoSlower() async throws {
        let engine = try Self.engine(Self.whisperMedium)
        let (audio, _) = try Self.dictation(seconds: 45)
        let inc = IncrementalTranscriber(engine: engine, options: Self.options, policy: .forModelFamily("whisper"))
        var fed = 0
        while fed < audio.count, !inc.hasStarted {
            let next = min(fed + 32_000, audio.count)
            inc.append(Array(audio[fed..<next]))
            fed = next
        }
        try #require(inc.hasStarted, "a segment should start past 30 s")
        // The user lets go right now: the recording ends where the segment started.
        let recording = Array(audio[..<fed])
        let released = MonoClock.nowNs()
        let result = try await inc.finish(complete: recording)
        let releaseMs = MonoClock.ms(from: released, to: MonoClock.nowNs())
        let oneShotMs = (0..<2).map { _ in
            let t0 = MonoClock.nowNs()
            _ = try? engine.transcribe(pcm: recording, options: Self.options)
            return MonoClock.ms(from: t0, to: MonoClock.nowNs())
        }.min() ?? 0
        #expect(releaseMs <= oneShotMs * 1.15 + 50, "release \(Int(releaseMs)) ms vs one-shot \(Int(oneShotMs)) ms")
        #expect(!result.text.isEmpty)
    }

    @Test func aFailedSegmentLeavesTheWorkToRelease() async throws {
        let (audio, _) = try Self.dictation(seconds: 16)
        let inc = IncrementalTranscriber(engine: UtterEngine(), options: Self.options) // no model loaded
        inc.append(audio)
        while inc.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(inc.segments == 0)
        inc.append([Float](repeating: 0, count: 32_000)) // no retry storm after a failure
        #expect(!inc.isBusy)
        await #expect(throws: CoreError.self) { try await inc.finish(complete: audio) } // surfaced the normal way
    }

    /// Typing as you speak: a phrase of background noise isn't typed or
    /// dropped; it's held and heard again with the next phrase that has a voice.
    @Test func aPhraseWithoutAVoiceIsHeldForTheNextOne() async throws {
        let engine = try Self.engine()
        var seed: UInt32 = 12345
        let noise = (0..<32_000).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.06
        }
        let speech = try loadWav16kMono(path: Self.fixturesDir.appendingPathComponent("tts_01.wav").path)
        let pause = [Float](repeating: 0, count: 12_800)
        let audio = noise + pause + speech + pause
        let inc = IncrementalTranscriber(engine: engine, options: Self.options, policy: .live)
        let typed = LockedTexts()
        inc.onSegment = { _, text in typed.append(text) }
        var fed = 0
        var heldChecked = false
        while fed < audio.count {
            let next = min(fed + 1_600, audio.count)
            inc.append(Array(audio[fed..<next]))
            fed = next
            while inc.isBusy { try await Task.sleep(for: .milliseconds(5)) }
            if !heldChecked, fed >= noise.count + pause.count {
                // The noise phrase was cut and checked: nothing typed, nothing committed.
                #expect(inc.segments == 0 && typed.all.isEmpty)
                #expect(inc.committedSnapshot.samples == 0)
                heldChecked = true
            }
        }
        let result = try await inc.finish(complete: audio)
        #expect(result.segments == 1, "noise and sentence went in as one phrase")
        #expect(typed.all.count == 1)
        #expect(result.text.lowercased().contains("testing"), "\(result.text)")
    }

    @Test func shortDictationsNeverSegment() {
        let inc = IncrementalTranscriber(engine: UtterEngine(), options: Self.options)
        inc.append([Float](repeating: 0.1, count: 16_000 * 5))
        #expect(!inc.hasStarted && !inc.isBusy && inc.segments == 0, "under 10 s nothing is cut")
    }

    @Test func cjkSegmentsJoinWithoutSpaces() {
        #expect(IncrementalTranscriber.join(["今天天气很好。", "我们去公园。"]) == "今天天气很好。我们去公园。")
        #expect(IncrementalTranscriber.join(["Hello there.", "How are you?"]) == "Hello there. How are you?")
        #expect(IncrementalTranscriber.join(["ok.", "日本語"]) == "ok. 日本語")
    }
}

/// Texts typed by `onSegment`, which runs on the transcriber's queue.
final class LockedTexts: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func append(_ text: String) { lock.withLock { texts.append(text) } }
    var all: [String] { lock.withLock { texts } }
}
