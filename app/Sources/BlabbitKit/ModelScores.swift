import Foundation
import BlabbitCore

/// 0–100 accuracy and speed scores for the model picker, derived from the
/// catalog's measured numbers (Apple M4, Blabbit's spoken test clips) rather than
/// hand-picked like Handy's.
public struct ModelScores: Equatable, Sendable {
    public let accuracy: Int
    public let speed: Int

    public init(wer: Double, rtf: Double) {
        accuracy = Self.accuracy(wer: wer)
        speed = Self.speed(rtf: rtf)
    }

    public init(_ entry: ModelEntry) {
        self.init(wer: entry.measuredWer, rtf: entry.measuredRtf)
    }

    /// Share of words right: WER 0.10 → 90.
    static func accuracy(wer: Double) -> Int {
        guard wer.isFinite, wer >= 0 else { return 0 }
        return Int((100 * (1 - wer)).rounded()).clamped(to: 0...100)
    }

    /// Log scale, because real-time factors span 40×: RTF 0.01 (5 s of speech in
    /// 50 ms) scores 100, and every 10× slower costs 40 points (RTF 0.5 → 32).
    static func speed(rtf: Double) -> Int {
        guard rtf.isFinite, rtf > 0 else { return 0 }
        return Int((100 - 40 * log10(rtf / 0.01)).rounded()).clamped(to: 0...100)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
