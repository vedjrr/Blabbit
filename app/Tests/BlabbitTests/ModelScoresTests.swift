import Testing
@testable import BlabbitKit

@Suite struct ModelScoresTests {
    @Test func accuracyIsTheShareOfWordsRight() {
        #expect(ModelScores(wer: 0.10, rtf: 0.02).accuracy == 90)
        #expect(ModelScores(wer: 0.343, rtf: 0.02).accuracy == 66)
        #expect(ModelScores(wer: 0, rtf: 0.02).accuracy == 100)
        #expect(ModelScores(wer: 1.4, rtf: 0.02).accuracy == 0, "insertions can push WER past 1")
        #expect(ModelScores(wer: .nan, rtf: 0.02).accuracy == 0)
    }

    @Test func speedIsLogarithmicInTheRealTimeFactor() {
        #expect(ModelScores(wer: 0.2, rtf: 0.01).speed == 100)
        #expect(ModelScores(wer: 0.2, rtf: 0.1).speed == 60)
        #expect(ModelScores(wer: 0.2, rtf: 0.503).speed == 32)
        #expect(ModelScores(wer: 0.2, rtf: 0.001).speed == 100)
        #expect(ModelScores(wer: 0.2, rtf: 50).speed == 0)
        #expect(ModelScores(wer: 0.2, rtf: 0).speed == 0, "an unmeasured model never looks fastest")
    }

    /// The bars must order the catalog the way the measurements do.
    @MainActor @Test func catalogScoresFollowTheMeasurements() {
        let entries = ModelManager().entries
        #expect(!entries.isEmpty)
        for a in entries {
            let sa = ModelScores(a)
            #expect((0...100).contains(sa.accuracy) && (0...100).contains(sa.speed))
            for b in entries {
                let sb = ModelScores(b)
                if a.measuredRtf < b.measuredRtf { #expect(sa.speed >= sb.speed, "\(a.id) vs \(b.id)") }
                if a.measuredWer < b.measuredWer { #expect(sa.accuracy >= sb.accuracy, "\(a.id) vs \(b.id)") }
            }
        }
    }
}
