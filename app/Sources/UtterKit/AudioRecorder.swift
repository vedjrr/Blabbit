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
    /// The input device/format changed mid-recording; audio after that point is missing.
    public var interruptedByDeviceChange = false
    /// With `interruptedByDeviceChange`: the device capture continued on
    /// (nil if audio after the change was lost).
    public var continuedOnDevice: String?
    /// Audio included from before the start (Keep Microphone Ready's pre-roll).
    public var preRollMs: Double = 0
    /// False if the microphone never started for this recording.
    public var didRecord = true
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
/// and the recorder's serial queue (consumer). Storage is allocated once. Both
/// sides take a tiny unfair lock only to read/update indices (and the producer
/// to copy one IO buffer); nothing allocates while holding it.
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

    /// Consumer: moves everything written so far into `out`. The copy happens
    /// outside the lock: with one producer and one consumer the producer never
    /// touches samples in [read, write), so only the indices need the lock.
    /// This keeps allocation (appending to `out`) off the realtime thread's path.
    func drain(into out: inout [Float]) {
        let (read, write) = cursor.withLock { ($0.read, $0.write) }
        var n = write - read
        guard n > 0 else { return }
        out.reserveCapacity(out.count + n)
        var position = read
        while n > 0 {
            let start = position % capacity
            let chunk = min(n, capacity - start)
            out.append(contentsOf: UnsafeBufferPointer(start: storage + start, count: chunk))
            position += chunk
            n -= chunk
        }
        cursor.withLock { $0.read = write }
    }

    /// Realtime thread: records frames the callback could not accept.
    func noteDropped(_ count: Int) {
        guard count > 0 else { return }
        cursor.withLock { $0.dropped += count }
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
    /// Set when the device changed mid-recording (reported on the Recording).
    private var interrupted = false
    /// The device capture moved to after a mid-recording change.
    private var continuedOn: String?
    private var configObserver: NSObjectProtocol?
    private let levelState = OSAllocatedUnfairLock(initialState: Float(0))
    private let recordingState = OSAllocatedUnfairLock(initialState: false)
    /// Scratch buffer for the realtime downmix, sized for the largest IO buffer.
    private var mixScratch: UnsafeMutablePointer<Float>?
    private let mixCapacity = 16_384

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

    /// The device the graph was last built for (on `queue`).
    public private(set) var activeDevice: AudioInputDevice?
    /// Set when the chosen device was missing and the default was used instead.
    public private(set) var missingPreferredDevice: String?
    // MARK: Keep the microphone ready (PARITY A11)
    //
    // Starting the input device takes 40–65 ms on this Mac (AVAudioEngine and a
    // bare AUHAL measure the same), so key-down → first audio can't be under
    // 50 ms from cold. With `keepReady`, input keeps running between dictations
    // and only the last `preRollSeconds` are kept, so a recording starts with
    // audio already in hand, including the moment just before the key-down.
    // macOS shows the microphone-in-use indicator the whole time.

    public private(set) var keepReady = false
    /// Capture stopped mid-recording and no device could take over (called on `queue`).
    public var onCaptureLost: (@Sendable () -> Void)?
    /// A graph was built for this device (called on `queue`), e.g. for the menu.
    public var onDeviceReady: (@Sendable (String?) -> Void)?
    public static let preRollSeconds = 0.15
    /// Input-rate mono samples from just before a recording starts.
    private var preRoll: [Float] = []
    private var idleTimer: DispatchSourceTimer?
    /// Whether the current recording began with a warm input.
    public private(set) var startedWarm = false
    /// Pre-roll length included in the current recording.
    private var preRollMs: Double = 0

    public func setKeepReady(_ on: Bool) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        keepReady = on
        Log.info("keep microphone ready \(on)")
        if on {
            try prepare()
            try runWarmIfIdle()
        } else if !isRecording {
            stopIdle()
            engine.pause()
            preRoll.removeAll()
        }
    }

    /// Starts the input for warm idling (not recording). No-op unless `keepReady`.
    private func runWarmIfIdle() throws {
        guard keepReady, !isRecording, sink != nil else { return }
        if !engine.isRunning { try engine.start() }
        ring?.reset()
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drainIdle() }
        timer.resume()
        idleTimer = timer
    }

    private func stopIdle() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// Keeps only the newest `preRollSeconds` of idle audio.
    private func drainIdle() {
        guard let ring, !isRecording else { return }
        ring.drain(into: &preRoll)
        let keep = Int(inputRate * Self.preRollSeconds)
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
    }

    /// Device lookups (replaceable in tests to simulate a device that vanished).
    var lookupDevice: (String) -> AudioInputDevice? = AudioDevices.device(uid:)
    var defaultDevice: () -> AudioInputDevice? = AudioDevices.defaultInput
    /// Capture timing from before a device change, if the rebuild failed.
    private var cursorBeforeChange: SampleRing.Cursor?

    /// True while the input unit is pinned to a chosen device.
    private var deviceOverridden = false
    /// The chosen input device's UID; nil follows the system default. Set with `setPreferredDevice`.
    public private(set) var preferredDeviceUID: String?

    /// Chooses the input device (nil = system default). Rebuilds the graph now
    /// unless a recording is running (then on the next start).
    public func setPreferredDevice(uid: String?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard uid != preferredDeviceUID || sink == nil else { return }
        preferredDeviceUID = uid
        needsRebuild = true
        if !isRecording { try prepare() }
    }

    /// Points the engine's input unit at the chosen device (or the default).
    private func selectDevice() throws {
        let preferred = preferredDeviceUID.flatMap(lookupDevice)
        missingPreferredDevice = (preferredDeviceUID != nil && preferred == nil) ? preferredDeviceUID : nil
        guard let device = preferred ?? defaultDevice() else { throw AudioRecorderError.noInputDevice }
        // Following the system default: leave AVAudioEngine's own device choice
        // alone (it may use a private aggregate device, and setting the device
        // fires a configuration change) unless a specific device was set before.
        let mustSet = preferred != nil || deviceOverridden
        if mustSet, let unit = engine.inputNode.audioUnit, currentDevice(of: unit) != device.id {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                Log.error("could not select input device \(device.name) status=\(status)")
                throw AudioRecorderError.noInputDevice
            }
        }
        deviceOverridden = preferred != nil
        activeDevice = device
        if let missing = missingPreferredDevice {
            Log.info("chosen input device \(missing) is not connected; using \(device.name)")
        }
    }

    private func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr ? id : nil
    }

    /// Latest RMS level (0…1), for level meters. Any thread.
    public var level: Float { levelState.withLock { $0 } }
    /// Any thread.
    public var isRecording: Bool { recordingState.withLock { $0 } }

    /// Builds the capture graph for the current default input. Safe to call again.
    public func prepare() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        // Never tear down a live recording (e.g. a microphone chosen from the
        // menu mid-dictation): the change applies on the next start.
        guard !isRecording else { return }
        try buildGraph()
        try runWarmIfIdle()
    }

    private func buildGraph() throws {
        if sink != nil && !needsRebuild { return }
        teardownGraph()
        try selectDevice()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let resampler = Resampler(inputFormat: monoFormat)
        else { throw AudioRecorderError.unsupportedFormat }

        let ring = SampleRing(capacity: Int(format.sampleRate) * 8)
        let scratch = mixScratch ?? .allocate(capacity: mixCapacity)
        mixScratch = scratch
        let mixCapacity = self.mixCapacity
        let rate = format.sampleRate
        let channels = Int(format.channelCount)

        let sink = AVAudioSinkNode { timestamp, frameCount, bufferList -> OSStatus in
            let now = MonoClock.nowNs()
            let frames = min(Int(frameCount), mixCapacity)
            ring.noteDropped(Int(frameCount) - frames)
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
        onDeviceReady?(activeDevice?.name)
        Log.info("audio graph ready input_rate=\(Int(format.sampleRate)) channels=\(format.channelCount) device=\"\(activeDevice?.name ?? "?")\" bluetooth=\(activeDevice?.isBluetooth ?? false)")
    }

    private func teardownGraph() {
        stopIdle()
        preRoll.removeAll()
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
        // Warm only if input was already running before this call: `prepare()`
        // may cold-start it (after a failed rebuild), which is not warm.
        let wasRunning = engine.isRunning && sink != nil
        try prepare()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16_000 * 60)
        interrupted = false
        continuedOn = nil
        cursorBeforeChange = nil
        levelState.withLock { $0 = 0 }
        resampler?.reset()
        stopIdle()
        drainIdle()
        if keepReady, wasRunning, engine.isRunning, !preRoll.isEmpty, let ring {
            // Warm: audio is already flowing. Take the pre-roll, then keep going.
            let now = MonoClock.nowNs()
            ring.cursor.withLock { c in
                c.dropped = 0
                c.waitUntilNs = nil
                // Audio is in hand from before this instant (the pre-roll).
                c.firstSampleNs = now
                c.firstCallbackNs = now
            }
            recordingState.withLock { $0 = true }
            startedWarm = true
            preRollMs = Double(preRoll.count) / inputRate * 1000
            convertIntoSamples(preRoll)
            preRoll.removeAll(keepingCapacity: true)
            startDrainTimer()
            return
        }
        startedWarm = false
        preRollMs = 0
        preRoll.removeAll(keepingCapacity: true)
        ring?.reset()
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

    /// The 16 kHz audio captured so far in this recording, from `index` on
    /// (incremental transcription). Call on `queue`.
    public func samplesSoFar(from index: Int) -> [Float] {
        dispatchPrecondition(condition: .onQueue(queue))
        drainAndConvert()
        guard index < samples.count else { return [] }
        return Array(samples[index...])
    }

    /// Stops after the audio up to `releaseNs` has arrived (bounded wait), so the
    /// last word is not cut off.
    public func stop(releaseNs: UInt64) -> Recording {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRecording || interrupted else {
            return Recording(samples: [], droppedFrames: 0, didRecord: false)
        }
        if isRecording, let ring {
            let alreadyThere = ring.cursor.withLock { c -> Bool in
                if c.lastEndNs >= releaseNs { return true }
                c.waitUntilNs = releaseNs
                return false
            }
            if !alreadyThere {
                _ = ring.tailArrived.wait(timeout: .now() + .milliseconds(150))
            }
        }
        if !keepReady { engine.pause() }
        recordingState.withLock { $0 = false }
        drainTimer?.cancel()
        drainTimer = nil
        drainAndConvert()
        samples.append(contentsOf: resampler?.flush() ?? [])
        // After a device change no device could take over, `ring` is gone: use
        // the timing saved before the change and keep the samples captured.
        let c = ring?.cursor.withLock { $0 } ?? cursorBeforeChange ?? SampleRing.Cursor()
        let recording = Recording(samples: samples, firstSampleNs: c.firstSampleNs, firstCallbackNs: c.firstCallbackNs,
                                  lastSampleEndNs: c.lastEndNs == 0 ? nil : c.lastEndNs, droppedFrames: c.dropped,
                                  interruptedByDeviceChange: interrupted, continuedOnDevice: continuedOn, preRollMs: preRollMs)
        samples = []
        interrupted = false
        continuedOn = nil
        cursorBeforeChange = nil
        levelState.withLock { $0 = 0 }
        // Apply a device chosen mid-recording now, not on the next key-down.
        if needsRebuild {
            do { try buildGraph() } catch { Log.error("rebuild after recording failed: \(error)") }
        }
        rewarm()
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
        guard let ring else { return }
        var raw: [Float] = []
        ring.drain(into: &raw)
        convertIntoSamples(raw)
    }

    /// Resamples input-rate mono audio to 16 kHz, appends it, updates the level.
    private func convertIntoSamples(_ raw: [Float]) {
        guard let resampler, !raw.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: resampler.inputFormat, frameCapacity: AVAudioFrameCount(raw.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(raw.count)
        guard let channel = buffer.floatChannelData?[0] else { return }
        raw.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: raw.count) }
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
            // Keep what was captured, then carry on with whatever device is now
            // available (the chosen one, or the default if it went away).
            drainTimer?.cancel()
            drainTimer = nil
            drainAndConvert()
            samples.append(contentsOf: resampler?.flush() ?? [])
            interrupted = true
            let before = ring?.cursor.withLock { $0 }
            cursorBeforeChange = before
            do {
                try buildGraph()
                if let before, let ring {
                    ring.cursor.withLock { c in
                        c.firstSampleNs = before.firstSampleNs
                        c.firstCallbackNs = before.firstCallbackNs
                        c.dropped = before.dropped
                    }
                }
                try engine.start()
                startDrainTimer()
                continuedOn = activeDevice?.name ?? "the default microphone"
                Log.info("input device changed while recording; continuing on \(continuedOn ?? "?") samples_so_far=\(samples.count)")
            } catch {
                recordingState.withLock { $0 = false }
                levelState.withLock { $0 = 0 }
                continuedOn = nil
                onCaptureLost?()
                Log.error("input device changed while recording and no device could take over; audio after the change is lost: \(error)")
            }
        } else {
            do { try buildGraph() } catch { Log.error("rebuild after configuration change failed: \(error)") }
            rewarm()
        }
    }

    /// Called when Keep Microphone Ready couldn't restart the input (on `queue`).
    public var onKeepReadyFailed: (@Sendable (String) -> Void)?

    /// Restarts warm idling after a recording or a rebuild. A failure is logged
    /// and reported (the next start is cold); the next graph build retries.
    private func rewarm() {
        guard keepReady else { return }
        do { try runWarmIfIdle() } catch {
            Log.error("keep microphone ready: could not restart input: \(error)")
            onKeepReadyFailed?("\(error)")
        }
    }

    /// Test hook: what a real `AVAudioEngineConfigurationChange` triggers.
    func simulateConfigurationChange() {
        dispatchPrecondition(condition: .onQueue(queue))
        handleConfigurationChange()
    }
}
