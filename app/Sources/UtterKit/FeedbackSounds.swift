import AVFoundation
import CoreAudio
import Foundation

/// Settings → Audio: feedback sounds, their output device, muting other audio
/// while recording (PARITY A9, A10, A15, A22). Everything is off by default, as in Handy.
public struct SoundSettings: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable {
        /// Two soft sine notes, rising to start and falling to stop.
        case soft
        /// Short, brighter blips.
        case bright
        /// The user's own sound files.
        case custom

        public var title: String {
            switch self {
            case .soft: "Soft"
            case .bright: "Bright"
            case .custom: "Custom Files"
            }
        }
    }

    public var enabled = false
    public var theme = Theme.soft
    /// 0…1.
    public var volume = 0.8
    /// Output device UID; nil plays on the system output.
    public var outputDeviceUID: String?
    public var customStartPath: String?
    public var customStopPath: String?
    public var muteWhileRecording = false

    public init() {}

    public static let defaultsKey = "audio.sounds"

    public static func load(from defaults: UserDefaults = .standard) -> SoundSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(SoundSettings.self, from: data) else { return SoundSettings() }
        return saved
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SoundSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? d.theme
        volume = min(max(try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume, 0), 1)
        outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        customStartPath = try c.decodeIfPresent(String.self, forKey: .customStartPath)
        customStopPath = try c.decodeIfPresent(String.self, forKey: .customStopPath)
        muteWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .muteWhileRecording) ?? d.muteWhileRecording
    }
}

public enum SoundCue: Sendable { case start, stop }

/// Original feedback tones, synthesised (no bundled or third-party audio).
public enum ToneSynth {
    public static let sampleRate = 48_000.0
    public static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    /// (frequency Hz, start s, length s) notes for a theme and cue.
    static func notes(_ theme: SoundSettings.Theme, _ cue: SoundCue) -> [(Double, Double, Double)] {
        switch (theme, cue) {
        case (.bright, .start): [(1318.5, 0, 0.05), (1760, 0.055, 0.07)]
        case (.bright, .stop): [(1760, 0, 0.05), (1318.5, 0.055, 0.07)]
        case (_, .start): [(659.3, 0, 0.09), (880, 0.08, 0.14)]
        case (_, .stop): [(880, 0, 0.09), (659.3, 0.08, 0.14)]
        }
    }

    public static func buffer(_ theme: SoundSettings.Theme, _ cue: SoundCue) -> AVAudioPCMBuffer? {
        let notes = notes(theme, cue)
        let total = (notes.map { $0.1 + $0.2 }.max() ?? 0) + 0.02
        let frames = AVAudioFrameCount(total * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { left[i] = 0 }
        let brightness = theme == .bright ? 0.35 : 0.12 // share of the 2nd harmonic
        for (freq, start, length) in notes {
            let first = Int(start * sampleRate)
            let count = Int(length * sampleRate)
            for n in 0..<count where first + n < Int(frames) {
                let t = Double(n) / sampleRate
                // 4 ms attack, then an exponential decay: no clicks at either end.
                let attack = min(1, t / 0.004)
                let decay = exp(-t / (length / 3.5))
                let wave = sin(2 * .pi * freq * t) + brightness * sin(4 * .pi * freq * t)
                left[first + n] += Float(0.28 * attack * decay * wave)
            }
        }
        right.update(from: left, count: Int(frames))
        return buffer
    }

    /// A user's sound file, converted to the player's format (at most 5 s).
    public static func load(path: String) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let frames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(file.processingFormat.sampleRate * 5)))
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: source, frameCount: frames)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let outFrames = AVAudioFrameCount(Double(source.frameLength) * sampleRate / file.processingFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outFrames) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

/// Plays feedback sounds on their own engine (never the capture engine), on
/// the chosen output device. The engine stops a few seconds after the last sound.
public final class FeedbackPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.utter.feedback", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var engineDeviceUID: String??
    private var idleStop: DispatchWorkItem?
    private var cache: [String: AVAudioPCMBuffer] = [:]

    public init() {}

    /// How long a cue lasts, so mute can wait for the start sound.
    public static func duration(_ settings: SoundSettings, _ cue: SoundCue) -> TimeInterval {
        guard settings.theme != .custom else { return 0.3 }
        let notes = ToneSynth.notes(settings.theme, cue)
        return notes.map { $0.1 + $0.2 }.max() ?? 0
    }

    /// Plays `cue` (even if sounds are off, when `force` is set: the Play button).
    public func play(_ cue: SoundCue, settings: SoundSettings, force: Bool = false) {
        guard settings.enabled || force else { return }
        queue.async { self.playNow(cue, settings) }
    }

    private func buffer(_ cue: SoundCue, _ settings: SoundSettings) -> AVAudioPCMBuffer? {
        if settings.theme == .custom {
            let path = cue == .start ? settings.customStartPath : settings.customStopPath
            if let path {
                if let cached = cache[path] { return cached }
                if let loaded = ToneSynth.load(path: path) {
                    cache[path] = loaded
                    return loaded
                }
                Log.error("feedback sound could not be read: \(path)")
            }
        }
        let theme: SoundSettings.Theme = settings.theme == .custom ? .soft : settings.theme
        let key = "\(theme.rawValue)-\(cue)"
        if let cached = cache[key] { return cached }
        let made = ToneSynth.buffer(theme, cue)
        cache[key] = made
        return made
    }

    /// Tests: plays synchronously and says whether the engine started.
    func playAndWait(_ cue: SoundCue, settings: SoundSettings) -> Bool {
        queue.sync { playNow(cue, settings) }
    }

    @discardableResult
    private func playNow(_ cue: SoundCue, _ settings: SoundSettings) -> Bool {
        guard let buffer = buffer(cue, settings) else { return false }
        do {
            let (engine, player) = try readyEngine(deviceUID: settings.outputDeviceUID)
            player.volume = Float(settings.volume)
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            if !player.isPlaying { player.play() }
        } catch {
            Log.error("feedback sound failed: \(error)")
            teardown()
            return false
        }
        idleStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in self?.teardown() }
        idleStop = stop
        queue.asyncAfter(deadline: .now() + 3, execute: stop)
        return true
    }

    private func readyEngine(deviceUID: String?) throws -> (AVAudioEngine, AVAudioPlayerNode) {
        if let engine, let player, engineDeviceUID == .some(deviceUID) {
            if !engine.isRunning { try engine.start() }
            return (engine, player)
        }
        teardown()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        if let deviceUID, let id = AudioDevices.outputDevice(uid: deviceUID)?.id, let unit = engine.outputNode.audioUnit {
            var device = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.error("feedback output device \(deviceUID) could not be selected status=\(status)") }
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: ToneSynth.format)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.player = player
        engineDeviceUID = .some(deviceUID)
        return (engine, player)
    }

    private func teardown() {
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        engineDeviceUID = nil
    }
}

/// Mutes the system output while recording and puts back exactly what was
/// there (an output that was already muted stays muted). PARITY A10.
public final class OutputMuter: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        var device: AudioDeviceID
        /// Non-nil: the device's mute switch was used.
        var wasMuted: Bool?
        /// Non-nil: no mute switch, so the volume was set to 0.
        var volume: Float32?
    }

    /// Core Audio access (replaceable in tests so they never touch real output).
    public struct Backend: Sendable {
        var defaultOutput: @Sendable () -> AudioDeviceID?
        var getMute: @Sendable (AudioDeviceID) -> Bool?
        var setMute: @Sendable (AudioDeviceID, Bool) -> Bool
        var getVolume: @Sendable (AudioDeviceID) -> Float32?
        var setVolume: @Sendable (AudioDeviceID, Float32) -> Bool
    }

    private let backend: Backend
    private let lock = NSLock()
    private var snapshot: Snapshot?

    public init(backend: Backend = .coreAudio) {
        self.backend = backend
    }

    public var isMuting: Bool { lock.lock(); defer { lock.unlock() }; return snapshot != nil }

    /// Mutes the default output. A second call before `restore` does nothing,
    /// so the snapshot is never our own muted state.
    @discardableResult
    public func mute() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard snapshot == nil, let device = backend.defaultOutput() else { return false }
        if let muted = backend.getMute(device) {
            guard backend.setMute(device, true) else { return false }
            snapshot = Snapshot(device: device, wasMuted: muted, volume: nil)
            return true
        }
        if let volume = backend.getVolume(device), backend.setVolume(device, 0) {
            snapshot = Snapshot(device: device, wasMuted: nil, volume: volume)
            return true
        }
        return false
    }

    /// Puts the output back as it was. Safe to call when nothing was muted.
    public func restore() {
        lock.lock(); defer { lock.unlock() }
        guard let s = snapshot else { return }
        snapshot = nil
        if let wasMuted = s.wasMuted { _ = backend.setMute(s.device, wasMuted) }
        if let volume = s.volume { _ = backend.setVolume(s.device, volume) }
    }
}

extension OutputMuter.Backend {
    public static let coreAudio = OutputMuter.Backend(
        defaultOutput: {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var id = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
                  id != kAudioObjectUnknown else { return nil }
            return id
        },
        getMute: { id in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(id, &address), AudioObjectIsPropertySettable(id, &address, &settable) == noErr,
                  settable.boolValue else { return nil }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value != 0
        },
        setMute: { id, on in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = on ? 1 : 0
            return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        },
        getVolume: { id in
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(id, &address),
                  AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value
        },
        setVolume: { id, volume in
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var value = volume
            return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        })
}
