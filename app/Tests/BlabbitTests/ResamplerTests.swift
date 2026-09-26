import AVFoundation
import Testing
@testable import BlabbitKit

@Suite struct ResamplerTests {
    /// 1 s of a 440 Hz tone, stereo at 48 kHz, in 1024-frame buffers like the mic tap.
    func toneBuffers(rate: Double = 48_000, channels: AVAudioChannelCount = 2, seconds: Double = 1) -> (AVAudioFormat, [AVAudioPCMBuffer]) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let total = Int(rate * seconds)
        var buffers: [AVAudioPCMBuffer] = []
        var n = 0
        while n < total {
            let frames = min(1024, total - n)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            b.frameLength = AVAudioFrameCount(frames)
            for c in 0..<Int(channels) {
                for i in 0..<frames {
                    b.floatChannelData![c][i] = 0.5 * sin(2 * .pi * 440 * Float(n + i) / Float(rate))
                }
            }
            buffers.append(b)
            n += frames
        }
        return (format, buffers)
    }

    @Test(arguments: [48_000.0, 44_100.0, 24_000.0, 16_000.0])
    func convertsToSixteenKilohertzMono(rate: Double) throws {
        let (format, buffers) = toneBuffers(rate: rate)
        let r = try #require(Resampler(inputFormat: format))
        var out: [Float] = []
        for b in buffers { out += r.convert(b) }
        out += r.flush()
        // Length: 1 s of input → 16 000 samples (±1 %).
        #expect(abs(out.count - 16_000) <= 160, "got \(out.count) samples from \(rate) Hz")
        // Frequency: count zero crossings in the steady middle; 440 Hz → 880 per second.
        let mid = out[1_600..<14_400]
        var crossings = 0
        for i in mid.indices.dropFirst() where (mid[i - 1] < 0) != (mid[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / 2 / (Double(mid.count) / 16_000)
        #expect(abs(hz - 440) < 5, "measured \(hz) Hz")
        // Level preserved when downmixing identical channels (peak ≈ 0.5).
        let peak = mid.map(abs).max() ?? 0
        #expect(peak > 0.45 && peak < 0.55, "peak \(peak)")
    }

    @Test func rejectsInvalidFormat() {
        let bad = AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)
        #expect(bad == nil || Resampler(inputFormat: bad!) == nil)
    }
}
