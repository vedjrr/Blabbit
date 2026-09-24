import AVFoundation
import os

/// A finished recording: 16 kHz mono samples plus capture timing.
public struct Recording: Sendable {
    public var samples: [Float]
    /// Host time (ns, `MonoClock`) at which the first captured sample was recorded.
    public var firstSampleNs: UInt64?
    public var durationMs: Double { Double(samples.count) / 16.0 }
}

public enum AudioRecorderError: Error, Equatable {
    case noInputDevice
    case unsupportedFormat
    case engineStartFailed(String)

    public var userMessage: String {
        switch self {
        case .noInputDevice: "No microphone is available. Connect one or check System Settings → Sound → Input."
        case .unsupportedFormat: "The microphone's audio format is not supported."
        case .engineStartFailed: "The microphone could not be started. Check that Utter has microphone access."
        }
    }
}

/// Captures the default input device with AVAudioEngine. `start`/`stop` may be
/// called from any thread; the tap runs on the audio thread and appends into a
/// lock-protected buffer reserved up front so the hot path does not allocate.
public final class AudioRecorder: @unchecked Sendable {
    private struct State {
        var samples: [Float] = []
        var firstSampleNs: UInt64?
        var recording = false
        var level: Float = 0
    }

    private let engine = AVAudioEngine()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var resampler: Resampler?
    private var tapInstalled = false
    private let control = NSLock()

    public init() {}

    /// Latest RMS level (0…1) of the incoming audio, for level meters.
    public var level: Float { state.withLock { $0.level } }

    public var isRecording: Bool { state.withLock { $0.recording } }

    private func installTapIfNeeded() throws {
        if tapInstalled { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
        guard let resampler = Resampler(inputFormat: format) else { throw AudioRecorderError.unsupportedFormat }
        self.resampler = resampler
        // ~20 ms buffers at 48 kHz; the engine may round this.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            self?.handle(buffer: buffer, time: time)
        }
        tapInstalled = true
        engine.prepare()
    }

    /// Prepares the engine ahead of time so `start()` is as fast as possible.
    public func prepare() throws {
        control.lock()
        defer { control.unlock() }
        try installTapIfNeeded()
    }

    public func start() throws {
        control.lock()
        defer { control.unlock() }
        try installTapIfNeeded()
        resampler?.reset()
        state.withLock { s in
            s.samples.removeAll(keepingCapacity: true)
            s.samples.reserveCapacity(16_000 * 60)
            s.firstSampleNs = nil
            s.recording = true
        }
        do {
            try engine.start()
        } catch {
            state.withLock { $0.recording = false }
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }
    }

    public func stop() -> Recording {
        control.lock()
        defer { control.unlock() }
        engine.pause()
        let tail = resampler?.flush() ?? []
        return state.withLock { s in
            s.recording = false
            s.samples.append(contentsOf: tail)
            let rec = Recording(samples: s.samples, firstSampleNs: s.firstSampleNs)
            s.samples = []
            s.level = 0
            return rec
        }
    }

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard state.withLock({ $0.recording }), let resampler else { return }
        let converted = resampler.convert(buffer)
        var sum: Float = 0
        for s in converted { sum += s * s }
        let rms = converted.isEmpty ? 0 : (sum / Float(converted.count)).squareRoot()
        let hostNs = time.isHostTimeValid ? MonoClock.ns(fromHostTime: time.hostTime) : MonoClock.nowNs()
        state.withLock { s in
            guard s.recording else { return }
            if s.firstSampleNs == nil { s.firstSampleNs = hostNs }
            s.samples.append(contentsOf: converted)
            s.level = rms
        }
    }
}
