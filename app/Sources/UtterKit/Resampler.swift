import AVFoundation

/// Converts capture buffers (any rate, any channel count) to 16 kHz mono Float32,
/// the format every Utter model takes. Stateful: keeps the resampling filter
/// history between buffers so there are no clicks at buffer boundaries.
public final class Resampler {
    public static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Resampler.targetFormat)
        else { return nil }
        if inputFormat.channelCount > 1 {
            // Mix all input channels down to mono instead of taking channel 0.
            converter.downmix = true
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.inputFormat = inputFormat
        self.converter = converter
    }

    public func reset() {
        converter.reset()
    }

    /// Converts one buffer; returns the 16 kHz mono samples it produced.
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = Resampler.targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Resampler.targetFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Drains samples still held in the converter's filter at end of recording.
    public func flush() -> [Float] {
        guard let out = AVAudioPCMBuffer(pcmFormat: Resampler.targetFormat, frameCapacity: 4096) else { return [] }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
