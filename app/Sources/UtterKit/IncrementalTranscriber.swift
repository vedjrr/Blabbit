import Foundation
import UtterCore

/// Transcribes a long dictation in segments while the user is still speaking,
/// cutting only in natural pauses (`findPause`), so on release just the tail
/// is left: a 5-minute recording needed 0.2 s of work at release instead of
/// 15.8 s, with no loss of accuracy (ADR-013). Call `append` from one serial
/// queue (the app uses its audio queue); state reads are thread-safe, and
/// segments run one at a time on the transcriber's own serial queue.
public final class IncrementalTranscriber: @unchecked Sendable {
    /// When segmenting pays off, per model family (measured, ADR-013).
    public struct Policy: Equatable, Sendable {
        /// A segment is at least this long.
        public var minSegmentSeconds: Double
        /// …and at most this long (nil: any length).
        public var maxSegmentSeconds: Double?
        /// No segment starts before the recording is this long.
        public var startAfterSeconds: Double

        /// Parakeet, Moonshine, SenseVoice: cost grows with length, so any
        /// segment ≥ 10 s taken off the release is a gain.
        public static let proportional = Policy(minSegmentSeconds: 10, maxSegmentSeconds: nil, startAfterSeconds: 0)
        /// Whisper pads every call to a 30 s window: a segment must fit in one
        /// window, and segmenting only starts once one-shot would need two
        /// (otherwise segment + tail = two windows where one-shot is one).
        public static let whisperWindow = Policy(minSegmentSeconds: 20, maxSegmentSeconds: 29.5, startAfterSeconds: 30)

        public static func forModelFamily(_ family: String?) -> Policy {
            family == "whisper" ? .whisperWindow : .proportional
        }
    }

    public static let minPauseSeconds = 0.35
    /// How far back `findPause` looks (no maximum segment): bounded, so a long
    /// monologue without a pause doesn't rescan minutes of audio every 2 s.
    static let searchWindowSeconds = 60.0

    public let policy: Policy
    private let engine: UtterEngine
    private var options: DictationOptions
    private let queue = DispatchQueue(label: "dev.utter.incremental", qos: .userInitiated)
    private let lock = NSLock()
    /// Audio not yet transcribed (committed audio is dropped).
    private var pending: [Float] = []
    /// Total samples received, and how many of them are transcribed.
    private var received = 0
    private var committed = 0
    private var texts: [String] = []
    private var busy = false
    private var failed = false
    private var inferenceMs = 0.0
    private var trimmedMs: UInt64 = 0
    private var segmentCount = 0

    public init(engine: UtterEngine, options: DictationOptions, policy: Policy = .proportional) {
        self.engine = engine
        self.options = options
        self.policy = policy
    }

    /// Segments transcribed so far.
    public var segments: Int { lock.lock(); defer { lock.unlock() }; return segmentCount }
    /// A segment is being transcribed right now.
    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    /// Samples fed so far (the recorder index to continue from).
    public var fed: Int { lock.lock(); defer { lock.unlock() }; return received }
    /// Audio already transcribed (16 kHz samples) and its text, for the live overlay.
    public var committedSnapshot: (samples: Int, text: String) {
        lock.lock(); defer { lock.unlock() }
        return (committed, Self.join(texts))
    }
    /// True once any segment was started: the release must go through `finish`
    /// (a one-shot pass would first wait for that segment, then redo its audio).
    public var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return segmentCount > 0 || busy }

    /// Adds newly captured audio and, if a pause makes a segment ready and
    /// nothing is running, transcribes it in the background.
    public func append(_ chunk: [Float]) {
        lock.lock()
        pending.append(contentsOf: chunk)
        received += chunk.count
        guard !busy, !failed, Double(received) > policy.startAfterSeconds * 16_000 else { lock.unlock(); return }
        let offset: Int
        let recent: [Float]
        if let maxSegment = policy.maxSegmentSeconds {
            // Look only within the first `maxSegment` of what's pending.
            offset = 0
            recent = Array(pending.prefix(Int(maxSegment * 16_000)))
        } else {
            // Search only the recent window; a cut before it is found on earlier calls.
            let window = Int(Self.searchWindowSeconds * 16_000)
            offset = max(0, pending.count - window)
            recent = Array(pending[offset...])
        }
        lock.unlock()
        let minSegment = max(0, Int(policy.minSegmentSeconds * 16_000) - offset)
        guard let cutInRecent = findPause(pcm: recent, from: 0, minSegmentSamples: UInt64(minSegment),
                                          minSilenceSamples: UInt64(Self.minPauseSeconds * 16_000)) else { return }
        let cut = offset + Int(cutInRecent)
        lock.lock()
        guard !busy, cut <= pending.count else { lock.unlock(); return }
        let segment = Array(pending[..<cut])
        busy = true
        let options = self.options
        lock.unlock()
        queue.async { [self] in
            let outcome = Swift.Result { try engine.transcribe(pcm: segment, options: options) }
            lock.lock()
            defer { busy = false; lock.unlock() }
            switch outcome {
            case .success(let result):
                if !result.text.isEmpty { texts.append(result.text) }
                // Whisper detects the language per call: keep the first detection
                // so later segments of the same dictation agree.
                if self.options.language == nil, let language = result.language, !language.isEmpty {
                    self.options.language = language
                }
                inferenceMs += result.inferenceMs
                trimmedMs += result.trimmedMs
                pending.removeFirst(segment.count)
                committed += segment.count
                segmentCount += 1
            case .failure(let error):
                // Leave everything to the release pass, which reports the error
                // (and triggers the damaged-model check) the normal way.
                failed = true
                Log.error("incremental segment failed; the rest is transcribed on release: \((error as? CoreError)?.logDetail ?? "\(error)")")
            }
        }
    }

    public struct Result: Sendable {
        public var text: String
        /// Work done after release (waiting for a running segment + the tail).
        public var tailInferenceMs: Double
        public var totalInferenceMs: Double
        public var segments: Int
        public var skipped: SkipReason?
        public var language: String?
        /// Silence removed across all segments (ms).
        public var trimmedMs: UInt64 = 0

        public init(text: String, tailInferenceMs: Double, totalInferenceMs: Double, segments: Int, skipped: SkipReason?, language: String?) {
            self.text = text
            self.tailInferenceMs = tailInferenceMs
            self.totalInferenceMs = totalInferenceMs
            self.segments = segments
            self.skipped = skipped
            self.language = language
        }
    }

    /// Call after the recording stops with its complete audio: waits for a
    /// running segment, transcribes the rest, joins everything.
    public func finish(complete: [Float]) async throws -> Result {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() } // a running segment finishes first
        }
        let (from, before, doneMs, count, options) = snapshot(limit: complete.count)
        // The tail runs on the transcriber's queue, not a Swift concurrency thread.
        let engine = self.engine
        let rest = Array(complete[from...])
        let tail: TranscriptionResult = try await withCheckedThrowingContinuation { done in
            queue.async { done.resume(with: Swift.Result { try engine.transcribe(pcm: rest, options: options) }) }
        }
        let parts = (before + [tail.text]).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var result = Result(text: Self.join(parts), tailInferenceMs: tail.inferenceMs,
                            totalInferenceMs: doneMs + tail.inferenceMs, segments: count,
                            skipped: parts.isEmpty ? tail.skipped : nil, language: options.language ?? tail.language)
        result.trimmedMs = lock.withLock { trimmedMs } + tail.trimmedMs
        return result
    }

    private func snapshot(limit: Int) -> (Int, [String], Double, Int, DictationOptions) {
        lock.lock()
        defer { lock.unlock() }
        return (min(committed, limit), texts, inferenceMs, segmentCount, options)
    }

    /// Joins segment texts: with a space, except between CJK characters
    /// (Chinese, Japanese, Korean text has no spaces between sentences).
    static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            if let last = out.unicodeScalars.last, let first = part.unicodeScalars.first,
               !(isCJK(last) && isCJK(first)) {
                out += " "
            }
            out += part
        }
        return out
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: true
        default: false
        }
    }
}
