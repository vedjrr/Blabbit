import AVFoundation
import os

/// A finished recording: 16 kHz mono samples plus capture timing.
public struct Recording: Sendable {
    public var samples: [Float]
    /// Host time (ns, `MonoClock`) of the first captured sample.
    public var firstSampleNs: UInt64?
    /// When the first audio callback actually ran (ns, `MonoClock`).
    public var firstCallbackNs: UInt64?
    /// Host time of the end of the last captured sample.
    public var lastSampleEndNs: UInt64?
    /// Samples lost because the drain fell behind (should be 0).
    public var droppedFrames: Int
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

/// Mono float ring buffer shared between the realtime audio thread (producer)
/// and the recorder's serial queue (consumer). Storage is allocated once; the
/// realtime side only copies under an uncontended unfair lock.
final class SampleRing: @unchecked Sendable {
    struct Cursor {
        var write = 0
        var read = 0
        var dropped = 0
        var firstSampleNs: UInt64?
        var firstCallbackNs: UInt64?
        var lastEndNs: UInt64 = 0
        var waitUntilNs: UInt64?
    }

    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    let cursor = OSAllocatedUnfairLock(initialState: Cursor())
    /// Signalled by the producer once audio up to `waitUntilNs` has arrived.
    let tailArrived = DispatchSemaphore(value: 0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    func reset() {
        cursor.withLock { $0 = Cursor() }
        while tailArrived.wait(timeout: .now()) == .success {}
    }

    /// Realtime thread. `mono` holds `count` samples; `hostNs`/`endNs` bound them in time.
    func write(_ mono: UnsafePointer<Float>, count: Int, hostNs: UInt64, endNs: UInt64, nowNs: UInt64) {
        // withLockUnchecked: the critical section copies through raw pointers.
        let signal = cursor.withLockUnchecked { c -> Bool in
            if c.firstSampleNs == nil {
                c.firstSampleNs = hostNs
                c.firstCallbackNs = nowNs
            }
            let free = capacity - (c.write - c.read)
            let n = min(count, free)
            c.dropped += count - n
            var i = 0
            while i < n {
                let start = (c.write + i) % capacity
                let chunk = min(n - i, capacity - start)
                (storage + start).update(from: mono + i, count: chunk)
                i += chunk
            }
            c.write += n
            c.lastEndNs = endNs
            if let until = c.waitUntilNs, endNs >= until {
                c.waitUntilNs = nil
                return true
            }
            return false
        }
        if signal { tailArrived.signal() }
    }

    /// Consumer: moves everything written so far into `out`.
    func drain(into out: inout [Float]) {
        var drained: [Float] = []
        cursor.withLockUnchecked { c in
            var n = c.write - c.read
            drained.reserveCapacity(n)
            while n > 0 {
                let start = c.read % capacity
                let chunk = min(n, capacity - start)
                drained.append(contentsOf: UnsafeBufferPointer(start: storage + start, count: chunk))
                c.read += chunk
                n -= chunk
            }
        }
        out.append(contentsOf: drained)
    }
}

/// Captures the default input device with AVAudioEngine through an
/// `AVAudioSinkNode`, which delivers IO-sized buffers (~10 ms) rather than the
/// 100–400 ms chunks of an input tap. The realtime callback only downmixes and
/// copies into a preallocated ring; resampling to 16 kHz happens on `queue`.
/// All public methods must be called on `queue`.
public final class AudioRecorder: @unchecked Sendable {
    public let queue: DispatchQueue
    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    private var ring: SampleRing?
    private var resampler: Resampler?
    private var inputRate: Double = 0
    private var samples: [Float] = []
    private var drainTimer: DispatchSourceTimer?
    private var needsRebuild = false
    private var configObserver: NSObjectProtocol?
    private let levelState = OSAllocatedUnfairLock(initialState: Float(0))
    private let recordingState = OSAllocatedUnfairLock(initialState: false)
    /// Scratch buffer for the realtime downmix, sized for the largest IO buffer.
    private var mixScratch: UnsafeMutablePointer<Float>?
    private let mixCapacity = 8192

    public init(queue: DispatchQueue) {
        self.queue = queue
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChange() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        mixScratch?.deallocate()
    }

    /// Latest RMS level (0…1), for level meters. Any thread.
    public var level: Float { levelState.withLock { $0 } }
    /// Any thread.
    public var isRecording: Bool { recordingState.withLock { $0 } }

    /// Builds the capture graph for the current default input. Safe to call again.
    public func prepare() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if sink != nil && !needsRebuild { return }
        teardownGraph()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let resampler = Resampler(inputFormat: monoFormat)
        else { throw AudioRecorderError.unsupportedFormat }

        let ring = SampleRing(capacity: Int(format.sampleRate) * 8)
        if mixScratch == nil { mixScratch = .allocate(capacity: mixCapacity) }
        let scratch = mixScratch!
        let mixCapacity = self.mixCapacity
        let rate = format.sampleRate
        let channels = Int(format.channelCount)

        let sink = AVAudioSinkNode { timestamp, frameCount, bufferList -> OSStatus in
            let now = MonoClock.nowNs()
            let frames = min(Int(frameCount), mixCapacity)
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard frames > 0, !abl.isEmpty else { return noErr }
            // Non-interleaved float: one buffer per channel. Interleaved: one buffer, stride = channels.
            let interleaved = abl.count == 1 && channels > 1
            let gain = 1 / Float(channels)
            for i in 0..<frames { scratch[i] = 0 }
            if interleaved {
                guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += data[i * channels + c] }
                    scratch[i] = sum * gain
                }
            } else {
                for c in 0..<min(channels, abl.count) {
                    guard let data = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frames { scratch[i] += data[i] * gain }
                }
            }
            let ts = timestamp.pointee
            let hostNs = ts.mFlags.contains(.hostTimeValid) ? MonoClock.ns(fromHostTime: ts.mHostTime) : now
            let endNs = hostNs + UInt64(Double(frames) / rate * 1_000_000_000)
            ring.write(scratch, count: frames, hostNs: hostNs, endNs: endNs, nowNs: now)
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        self.sink = sink
        self.ring = ring
        self.resampler = resampler
        self.inputRate = format.sampleRate
        needsRebuild = false
        Log.info("audio graph ready input_rate=\(Int(format.sampleRate)) channels=\(format.channelCount)")
    }

    private func teardownGraph() {
        if engine.isRunning { engine.stop() }
        if let sink {
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
        }
        sink = nil
        ring = nil
        resampler = nil
    }

    public func start() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try prepare()
        ring?.reset()
        resampler?.reset()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16_000 * 60)
        levelState.withLock { $0 = 0 }
        do {
            try engine.start()
        } catch {
            // The device may have changed since prepare(); rebuild once and retry.
            Log.error("audio engine start failed, rebuilding: \(error.localizedDescription)")
            needsRebuild = true
            try prepare()
            do { try engine.start() } catch { throw AudioRecorderError.engineStartFailed(error.localizedDescription) }
        }
        recordingState.withLock { $0 = true }
        startDrainTimer()
    }

    /// Stops after the audio up to `releaseNs` has arrived (bounded wait), so the
    /// last word is not cut off.
    public func stop(releaseNs: UInt64) -> Recording {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let ring else { return Recording(samples: [], droppedFrames: 0) }
        if isRecording {
            let alreadyThere = ring.cursor.withLock { c -> Bool in
                if c.lastEndNs >= releaseNs { return true }
                c.waitUntilNs = releaseNs
                return false
            }
            if !alreadyThere {
                _ = ring.tailArrived.wait(timeout: .now() + .milliseconds(150))
            }
        }
        engine.pause()
        recordingState.withLock { $0 = false }
        drainTimer?.cancel()
        drainTimer = nil
        drainAndConvert()
        samples.append(contentsOf: resampler?.flush() ?? [])
        let c = ring.cursor.withLock { $0 }
        let recording = Recording(samples: samples, firstSampleNs: c.firstSampleNs, firstCallbackNs: c.firstCallbackNs,
                                  lastSampleEndNs: c.lastEndNs == 0 ? nil : c.lastEndNs, droppedFrames: c.dropped)
        samples = []
        levelState.withLock { $0 = 0 }
        return recording
    }

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.drainAndConvert() }
        timer.resume()
        drainTimer = timer
    }

    private func drainAndConvert() {
        guard let ring, let resampler else { return }
        var raw: [Float] = []
        ring.drain(into: &raw)
        guard !raw.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: resampler.inputFormat, frameCapacity: AVAudioFrameCount(raw.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(raw.count)
        raw.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: raw.count)
        }
        let converted = resampler.convert(buffer)
        samples.append(contentsOf: converted)
        if !converted.isEmpty {
            var sum: Float = 0
            for s in converted { sum += s * s }
            let rms = (sum / Float(converted.count)).squareRoot()
            levelState.withLock { $0 = rms }
        }
    }

    /// Device or format changed (AirPods connected, sample rate switched…).
    private func handleConfigurationChange() {
        Log.info("audio configuration changed recording=\(isRecording)")
        needsRebuild = true
        if isRecording {
            // Keep what was captured; the graph is rebuilt on the next start.
            drainAndConvert()
        } else {
            try? prepare()
        }
    }
}
