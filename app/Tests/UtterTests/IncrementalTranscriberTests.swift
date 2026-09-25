import Foundation
import Testing
import UtterCore
@testable import UtterKit

/// Long dictations are transcribed in segments while recording (real model).
@Suite(.serialized) struct IncrementalTranscriberTests {
    @Test func segmentsWhileRecordingAndLeavesOnlyTheTail() async throws {
        let model = ModelLocation.modelsDirectory.appendingPathComponent("parakeet-tdt-0.6b-v3/parakeet-tdt-0.6b-v3-Q8_0.gguf").path
        try #require(FileManager.default.fileExists(atPath: model), "run `make models` first")
        let engine = UtterEngine()
        _ = try engine.loadModel(path: model)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/audio")
        let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
        var audio: [Float] = []
        var reference = ""
        while audio.count < 45 * 16_000 {
            for wav in wavs {
                audio += try loadWav16kMono(path: wav.path)
                audio += [Float](repeating: 0, count: 12_800) // 0.8 s pause
                reference += (try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) + " "
            }
        }
        let options = DictationOptions(language: nil, translate: false, initialPrompt: nil)
        let inc = IncrementalTranscriber(engine: engine, options: options)
        // As captured: 2 s at a time, with the (fast) segment work running meanwhile.
        var fed = 0
        while fed < audio.count {
            let next = min(fed + 32_000, audio.count)
            inc.append(Array(audio[fed..<next]))
            fed = next
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(inc.fed == audio.count)
        let result = try inc.finish(complete: audio)
        let oneShot = try engine.transcribe(pcm: audio, options: options)
        #expect(result.segments >= 2, "segments \(result.segments)")
        #expect(result.tailInferenceMs * 2 < oneShot.inferenceMs, "tail \(result.tailInferenceMs) ms vs one-shot \(oneShot.inferenceMs) ms")
        // No accuracy lost against what was actually said (one-shot degrades on
        // long audio, so it isn't the yardstick).
        let segmented = wordErrorRate(reference: reference, hypothesis: result.text)
        let whole = wordErrorRate(reference: reference, hypothesis: oneShot.text)
        #expect(segmented <= whole + 0.02, "segmented \(segmented) vs one-shot \(whole)")
    }

    @Test func shortDictationsNeverSegment() throws {
        let inc = IncrementalTranscriber(engine: UtterEngine(), options: DictationOptions(language: nil, translate: false, initialPrompt: nil))
        inc.append([Float](repeating: 0.1, count: 16_000 * 5))
        #expect(inc.segments == 0, "under 10 s nothing is cut")
    }
}
