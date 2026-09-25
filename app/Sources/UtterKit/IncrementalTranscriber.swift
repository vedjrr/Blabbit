import Foundation
import UtterCore

/// Transcribes a long dictation in segments while the user is still speaking,
/// cutting only in natural pauses (`findPause`), so on release just the tail
/// is left: a 5-minute recording needed 0.2 s of work at release instead of
/// 15.8 s, with no loss of accuracy (ADR-013). Thread-safe; segments run one
/// at a time on a serial queue.
public final class IncrementalTranscriber: @unchecked Sendable {
    public static let minSegmentSeconds = 10.0
    public static let minPauseSeconds = 0.35
    /// How far back `findPause` looks: bounded, so a long monologue without a
    /// pause doesn't rescan (and copy) minutes of audio every 2 s.
    static let searchWindowSeconds = 60.0

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
    private var segmentCount = 0

    public init(engine: UtterEngine, options: DictationOptions) {
        self.engine = engine
        self.options = options
    }

    /// Segments transcribed so far.
    public var segments: Int { lock.lock(); defer { lock.unlock() }; return segmentCount }
    /// A segment is being transcribed right now.
    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    /// Samples fed so far (the recorder index to continue from).
    public var fed: Int { lock.lock(); defer { lock.unlock() }; return received }
    /// True once any segment was started: the release must go through `finish`
    /// (a one-shot pass would first wait for that segment, then redo its audio).
    public var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return segmentCount > 0 || busy }

    /// Adds newly captured audio and, if a pause makes a segment ready and
    /// nothing is running, transcribes it in the background.
    public func append(_ chunk: [Float]) {
        lock.lock()
        pending.append(contentsOf: chunk)
        received += chunk.count
        guard !busy, !failed else { lock.unlock(); return }
        // Search only the recent window; a cut before it is found on earlier calls.
        let window = Int(Self.searchWindowSeconds * 16_000)
        let offset = max(0, pending.count - window)
        let recent = Array(pending[offset...])
        lock.unlock()
        let minSegment = max(0, Int(Self.minSegmentSeconds * 16_000) - offset)
        guard let cutInRecent = findPause(pcm: recent, from: 0, minSegmentSamples: UInt64(minSegment),
                                          minSilenceSamples: UInt64(Self.minPauseSeconds * 16_000)) else { return }
        let cut = offset + Int(cutInRecent)
        lock.lock()
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
    }

    /// Call after the recording stops with its complete audio: waits for a
    /// running segment, transcribes the rest, joins everything.
    public func finish(complete: [Float]) async throws -> Result {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() } // a running segment finishes first
        }
        let (from, before, doneMs, count, options) = snapshot(limit: complete.count)
        let tail = try engine.transcribe(pcm: Array(complete[from...]), options: options)
        let parts = (before + [tail.text]).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Result(text: Self.join(parts), tailInferenceMs: tail.inferenceMs,
                      totalInferenceMs: doneMs + tail.inferenceMs, segments: count,
                      skipped: parts.isEmpty ? tail.skipped : nil, language: options.language ?? tail.language)
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
