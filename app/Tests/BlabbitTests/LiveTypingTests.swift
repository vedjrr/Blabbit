import Foundation
import Testing
import BlabbitCore
@testable import BlabbitKit

/// Typing as you speak: phrases go into the app at each pause.
@Suite struct LiveTypingPolicyTests {
    @Test func appliesOnlyToFastModelsWithoutAIRewriting() {
        let on = InsertionSettings()
        #expect(on.typeWhileSpeaking, "on by default")
        #expect(LiveTypingPolicy.applies(settings: on, mode: .clean, family: "parakeet", measuredRTF: 0.02))
        #expect(!LiveTypingPolicy.applies(settings: on, mode: .professional, family: "parakeet", measuredRTF: 0.02),
                "AI modes need the whole text")
        #expect(!LiveTypingPolicy.applies(settings: on, mode: .clean, family: "whisper", measuredRTF: 0.02))
        #expect(!LiveTypingPolicy.applies(settings: on, mode: .clean, family: "parakeet", measuredRTF: 0.5), "too slow")
        #expect(!LiveTypingPolicy.applies(settings: on, mode: .clean, family: "custom", measuredRTF: 0), "unmeasured")
        var off = on
        off.typeWhileSpeaking = false
        #expect(!LiveTypingPolicy.applies(settings: off, mode: .clean, family: "parakeet", measuredRTF: 0.02))
        var clipboard = on
        clipboard.method = .clipboardOnly
        #expect(!LiveTypingPolicy.applies(settings: clipboard, mode: .clean, family: "parakeet", measuredRTF: 0.02))
    }

    @Test func settingDecodesOnWhenMissing() throws {
        let old = try JSONDecoder().decode(InsertionSettings.self, from: Data(#"{"method":"automatic"}"#.utf8))
        #expect(old.typeWhileSpeaking)
    }

    @Test func separators() {
        #expect(LiveTypingPolicy.separator(after: "", before: "Hello") == "")
        #expect(LiveTypingPolicy.separator(after: "Hello there.", before: "How are you") == " ")
        #expect(LiveTypingPolicy.separator(after: "Line one\n", before: "Line two") == "")
        #expect(LiveTypingPolicy.separator(after: "你好。", before: "我很好") == "")
    }

    @Test func remainderSkipsWhatWasTyped() {
        let segments = ["One.", "Two.", "Three."]
        #expect(LiveTypingPolicy.remainder(segments: segments, typed: [0, 1, 2], tail: "Four.") == "Four.")
        #expect(LiveTypingPolicy.remainder(segments: segments, typed: [0], tail: "Four.") == "Two. Three. Four.")
        #expect(LiveTypingPolicy.remainder(segments: segments, typed: [0, 1, 2], tail: " ") == "")
    }

    @Test func phrasesGetNoTrailingExtras() {
        var settings = InsertionSettings()
        settings.appendTrailingSpace = true
        settings.newlines = .spaces
        #expect(settings.finalText(" next\nline", isPart: true) == " next line")
        #expect(settings.finalText("end", isPart: false) == "end ")
        #expect(LiveTypingPolicy.partSettings(TextPipelineSettings()).autoPunctuation == false)
    }
}

/// The live policy with a real model: each phrase arrives once, in order, as
/// soon as its pause is heard, and the release pass never repeats one.
@Suite(.serialized) struct LiveTypingSegmentTests {
    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var phrases: [(Int, String)] = []
        func add(_ i: Int, _ s: String) { lock.withLock { phrases.append((i, s)) } }
    }

    @Test func phrasesArriveInOrderAndTheTailIsOnlyTheRest() async throws {
        let engine = try IncrementalTranscriberTests.engine()
        let (audio, reference) = try IncrementalTranscriberTests.dictation(seconds: 14, noise: 0.003)
        let inc = IncrementalTranscriber(engine: engine, options: IncrementalTranscriberTests.options, policy: .live)
        let collected = Collected()
        inc.onSegment = { collected.add($0, $1) }
        var fed = 0
        // 0.25 s of audio per feed, like the app's timer.
        while fed < audio.count {
            let next = min(fed + 4_000, audio.count)
            inc.append(Array(audio[fed..<next]))
            fed = next
            try await Task.sleep(for: .milliseconds(30))
        }
        let result = try await inc.finish(complete: audio)
        let phrases = collected.lock.withLock { collected.phrases }
        #expect(phrases.count >= 2, "a phrase per pause while speaking, got \(phrases.count)")
        #expect(phrases.map(\.0) == Array(phrases.indices), "in order, once each")
        #expect(phrases.map(\.1) == result.segmentTexts)
        let typed = Set(phrases.map(\.0))
        let whole = IncrementalTranscriber.join(result.segmentTexts + [result.tailText].filter { !$0.isEmpty })
        #expect(whole == result.text, "typed phrases + the rest = the whole text, nothing twice")
        let rest = LiveTypingPolicy.remainder(segments: result.segmentTexts, typed: typed, tail: result.tailText)
        #expect(rest == result.tailText)
        let wer = wordErrorRate(reference: reference, hypothesis: result.text)
        print("live phrases=\(phrases.count) wer=\(wer) text=\(result.text)")
        #expect(wer < 0.4)
    }
}
