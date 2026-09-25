import Foundation
import UtterCore

/// Transcribes a long dictation in segments while the user is still speaking,
/// cutting only in natural pauses (`findPause`), so on release just the tail
/// is left: a 62 s recording needed 180 ms of work at release instead of
/// 1281 ms, with no loss of accuracy (`incremental_segments_match_one_shot…`).
/// Thread-safe; segments run one at a time on a serial queue.
public final class IncrementalTranscriber: @unchecked Sendable {
    public static let minSegmentSeconds = 10.0
    public static let minPauseSeconds = 0.35

    private let engine: UtterEngine
    private let options: DictationOptions
    private let queue = DispatchQueue(label: "dev.utter.incremental", qos: .userInitiated)
    private let lock = NSLock()
    /// Audio received so far (16 kHz mono) and how much of it is transcribed.
    private var audio: [Float] = []
    private var committed = 0
    private var texts: [String] = []
    private var busy = false
    private var inferenceMs = 0.0
    public private(set) var segments = 0

    public init(engine: UtterEngine, options: DictationOptions) {
        self.engine = engine
        self.options = options
    }

    /// A segment is being transcribed right now.
    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }

    /// Samples fed so far (the recorder index to continue from).
    public var fed: Int { lock.lock(); defer { lock.unlock() }; return audio.count }

    /// Adds newly captured audio and, if a pause makes a segment ready and
    /// nothing is running, transcribes it in the background.
    public func append(_ chunk: [Float]) {
        lock.lock()
        audio.append(contentsOf: chunk)
        guard !busy else { lock.unlock(); return }
        let from = committed
        let pending = Array(audio[from...])
        lock.unlock()
        guard let cut = findPause(pcm: pending, from: 0, minSegmentSamples: UInt64(Self.minSegmentSeconds * 16_000),
                                  minSilenceSamples: UInt64(Self.minPauseSeconds * 16_000)) else { return }
        let segment = Array(pending[..<Int(cut)])
        lock.lock()
        busy = true
        lock.unlock()
        queue.async { [self] in
            let result = try? engine.transcribe(pcm: segment, options: options)
            lock.lock()
            if let result {
                if !result.text.isEmpty { texts.append(result.text) }
                inferenceMs += result.inferenceMs
                committed = from + segment.count
                segments += 1
            }
            // On failure the segment stays uncommitted and is retried with the tail.
            busy = false
            lock.unlock()
        }
    }

    public struct Result: Sendable {
        public var text: String
        /// Work done after release (the tail only).
        public var tailInferenceMs: Double
        public var totalInferenceMs: Double
        public var segments: Int
        public var skipped: SkipReason?
    }

    /// Call after the recording stops with its complete audio: waits for a
    /// running segment, transcribes the rest, joins everything.
    public func finish(complete: [Float]) throws -> Result {
        queue.sync {} // a running segment finishes first
        lock.lock()
        let from = min(committed, complete.count)
        let before = texts
        let doneMs = inferenceMs
        let count = segments
        lock.unlock()
        let tail = try engine.transcribe(pcm: Array(complete[from...]), options: options)
        let all = (before + [tail.text]).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Result(text: all.joined(separator: " "), tailInferenceMs: tail.inferenceMs,
                      totalInferenceMs: doneMs + tail.inferenceMs, segments: count,
                      skipped: all.isEmpty ? tail.skipped : nil)
    }
}
