import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import UtterKit

/// Feedback sounds, output mute, channel choice, clamshell microphone, extra
/// buffer and lazy close (PARITY A9 A10 A13 A14 A15 A17 A22 F21).
@Suite struct AudioOptionsTests {
    // MARK: Channel selection

    private func stereo(_ left: Float, _ right: Float, frames: Int = 8, interleaved: Bool) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        if interleaved {
            let data = try #require(abl[0].mData?.assumingMemoryBound(to: Float.self))
            for i in 0..<frames { data[2 * i] = left; data[2 * i + 1] = right }
        } else {
            for (c, value) in [left, right].enumerated() {
                let data = try #require(abl[c].mData?.assumingMemoryBound(to: Float.self))
                for i in 0..<frames { data[i] = value }
            }
        }
        return buffer
    }

    @Test(arguments: [false, true]) func aChosenChannelIsRecordedAlone(interleaved: Bool) throws {
        let buffer = try stereo(0.5, -0.25, interleaved: interleaved)
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        defer { out.deallocate() }
        ChannelMixer.mix(abl, frames: 8, channels: 2, channel: nil, into: out)
        #expect(abs(out[3] - 0.125) < 1e-6) // the average
        ChannelMixer.mix(abl, frames: 8, channels: 2, channel: 0, into: out)
        #expect(out[3] == 0.5)
        ChannelMixer.mix(abl, frames: 8, channels: 2, channel: 1, into: out)
        #expect(out[3] == -0.25)
        // A channel the device doesn't have (it was unplugged, a mono mic took over): mix.
        ChannelMixer.mix(abl, frames: 8, channels: 2, channel: 5, into: out)
        #expect(abs(out[3] - 0.125) < 1e-6)
    }

    // MARK: Settings

    @Test func settingsDecodeOldDataAndClamp() throws {
        #expect(SoundSettings().enabled == false && SoundSettings().muteWhileRecording == false)
        let sounds = try JSONDecoder().decode(SoundSettings.self, from: Data(#"{"enabled":true,"volume":7,"theme":"gone"}"#.utf8))
        #expect(sounds.enabled && sounds.volume == 1 && sounds.theme == .soft)
        let capture = try JSONDecoder().decode(CaptureSettings.self, from: Data(#"{"extraBufferMs":99999}"#.utf8))
        #expect(capture.extraBufferMs == 1000 && capture.trimSilence && !capture.lazyClose && capture.inputChannel == nil)
        let suite = "dev.utter.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var c = CaptureSettings()
        c.inputChannel = 1
        c.clamshellDeviceUID = "usb-mic"
        c.save(to: defaults)
        #expect(CaptureSettings.load(from: defaults) == c)
    }

    // MARK: Sounds

    @Test(arguments: [SoundSettings.Theme.soft, .bright]) func tonesAreShortAudibleAndClickFree(theme: SoundSettings.Theme) throws {
        for cue in [SoundCue.start, .stop] {
            let buffer = try #require(ToneSynth.buffer(theme, cue))
            let n = Int(buffer.frameLength)
            let data = try #require(buffer.floatChannelData?[0])
            let seconds = Double(n) / ToneSynth.sampleRate
            #expect(seconds > 0.08 && seconds < 0.4, "\(seconds) s")
            let peak = (0..<n).map { abs(data[$0]) }.max() ?? 0
            #expect(peak > 0.1 && peak <= 1)
            // Starts and ends near silence (no click).
            #expect(abs(data[0]) < 0.01 && abs(data[n - 1]) < 0.01)
        }
        // Start and stop sound different (rising vs falling).
        let start = try #require(ToneSynth.buffer(theme, .start))
        let stop = try #require(ToneSynth.buffer(theme, .stop))
        let a = try #require(start.floatChannelData?[0])
        let b = try #require(stop.floatChannelData?[0])
        #expect((0..<2000).contains { abs(a[$0] - b[$0]) > 0.05 })
        withExtendedLifetime((start, stop)) {}
        #expect(FeedbackPlayer.duration(SoundSettings(), .start) > 0.1)
    }

    @Test func customSoundFilesAreConverted() throws {
        let wav = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../fixtures/audio/tts_01.wav").standardized
        let buffer = try #require(ToneSynth.load(path: wav.path))
        #expect(buffer.format == ToneSynth.format)
        let seconds = Double(buffer.frameLength) / ToneSynth.sampleRate
        #expect(seconds > 4.5 && seconds <= 5.05, "capped at 5 s, got \(seconds)") // a 16 kHz mono clip, now 48 kHz stereo
        #expect(ToneSynth.load(path: "/no/such/file.wav") == nil)
    }

    @Test func theFeedbackEngineStartsOnTheSystemOutput() throws {
        try #require(!AudioDevices.outputDevices().isEmpty, "no output device")
        var silent = SoundSettings()
        silent.volume = 0 // exercise the real path without a sound in the room
        let player = FeedbackPlayer()
        #expect(player.playAndWait(.start, settings: silent))
        // A device that isn't connected: the system output is used instead.
        silent.outputDeviceUID = "unplugged-speaker"
        #expect(player.playAndWait(.stop, settings: silent))
    }

    // MARK: Mute while recording (fake Core Audio, so the tests never mute you)

    final class FakeOutput: @unchecked Sendable {
        var muted: Bool? = false
        var volume: Float32? = 0.6
        var sets: [String] = []
        var backend: OutputMuter.Backend {
            OutputMuter.Backend(
                defaultOutput: { 42 },
                getMute: { _ in self.muted },
                setMute: { _, on in
                    guard self.muted != nil else { return false }
                    self.muted = on; self.sets.append("mute=\(on)"); return true
                },
                getVolume: { _ in self.volume },
                setVolume: { _, v in self.volume = v; self.sets.append("volume=\(v)"); return true })
        }
    }

    @Test func muteRestoresWhatWasThere() {
        let out = FakeOutput()
        let muter = OutputMuter(backend: out.backend)
        #expect(muter.mute() && out.muted == true && muter.isMuting)
        // A second mute (late timer) must not snapshot our own muted state.
        #expect(!muter.mute())
        muter.restore()
        #expect(out.muted == false && !muter.isMuting)
        muter.restore() // nothing to restore: no change
        #expect(out.sets == ["mute=true", "mute=false"])
    }

    @Test func anAlreadyMutedOutputStaysMuted() {
        let out = FakeOutput()
        out.muted = true
        let muter = OutputMuter(backend: out.backend)
        muter.mute()
        muter.restore()
        #expect(out.muted == true)
    }

    @Test func withoutAMuteSwitchTheVolumeIsLoweredAndPutBack() {
        let out = FakeOutput()
        out.muted = nil // e.g. some USB and HDMI outputs
        let muter = OutputMuter(backend: out.backend)
        #expect(muter.mute() && out.volume == 0)
        muter.restore()
        #expect(out.volume == 0.6)
    }

    @Test func theRealOutputReportsAMuteSwitchOrAVolume() {
        // Read-only: never changes the user's output.
        let backend = OutputMuter.Backend.coreAudio
        guard let device = backend.defaultOutput() else { return }
        #expect(backend.getMute(device) != nil || backend.getVolume(device) != nil)
    }

    // MARK: Clamshell

    @Test func theLidStateIsReadable() {
        // On a laptop the property exists; on a desktop it doesn't, and "closed" is false.
        if !Clamshell.isLaptop { #expect(!Clamshell.isClosed()) }
    }
}

/// Needs the real microphone.
extension AudioHardwareTests { @Suite struct AudioOptionHardwareTests {
    @Test func withTheLidClosedTheClamshellMicrophoneIsUsed() throws {
        let queue = DispatchQueue(label: "dev.utter.test.clamshell")
        let recorder = AudioRecorder(queue: queue)
        let devices = AudioDevices.inputDevices()
        let other = try #require(devices.first { $0.uid != AudioDevices.defaultInput()?.uid } ?? devices.first)
        var closed = false
        queue.sync { recorder.lidIsClosed = { closed } }
        try queue.sync { try recorder.setClamshellDevice(uid: other.uid) }
        #expect(queue.sync { recorder.activeDevice?.uid } == AudioDevices.defaultInput()?.uid)
        // The lid closes: the next recording starts on the clamshell microphone.
        closed = true
        try queue.sync { try recorder.start() }
        #expect(queue.sync { recorder.activeDevice?.uid } == other.uid)
        _ = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
        closed = false
        try queue.sync { try recorder.start() }
        #expect(queue.sync { recorder.activeDevice?.uid } == AudioDevices.defaultInput()?.uid)
        _ = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
    }

    @Test func lazyCloseKeepsTheNextDictationWarmThenCloses() throws {
        let queue = DispatchQueue(label: "dev.utter.test.linger")
        let recorder = AudioRecorder(queue: queue)
        queue.sync { recorder.setLinger(seconds: 1.2) }
        try queue.sync { try recorder.start() }
        #expect(!recorder.startedWarm)
        Thread.sleep(forTimeInterval: 0.3)
        _ = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
        Thread.sleep(forTimeInterval: 0.3)
        // Within the linger window: warm, with pre-roll.
        try queue.sync { try recorder.start() }
        #expect(recorder.startedWarm)
        Thread.sleep(forTimeInterval: 0.2)
        let warm = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
        #expect(warm.preRollMs > 50, "pre-roll \(warm.preRollMs) ms")
        // After the window: the input was closed, so the start is cold.
        Thread.sleep(forTimeInterval: 1.6)
        try queue.sync { try recorder.start() }
        #expect(!recorder.startedWarm)
        _ = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
    }

    @Test func extraBufferAudioIsKept() throws {
        // The controller stops `extra` ms after release, asking for audio up to then.
        let queue = DispatchQueue(label: "dev.utter.test.extra")
        let recorder = AudioRecorder(queue: queue)
        try queue.sync { try recorder.start() }
        Thread.sleep(forTimeInterval: 0.3)
        let release = MonoClock.nowNs()
        let extraMs = 300
        let recording: Recording = queue.sync {
            Thread.sleep(forTimeInterval: Double(extraMs) / 1000)
            return recorder.stop(releaseNs: release + UInt64(extraMs) * 1_000_000)
        }
        let end = try #require(recording.lastSampleEndNs)
        #expect(end >= release + UInt64(extraMs - 30) * 1_000_000, "audio ends \(Double(Int64(end) - Int64(release)) / 1e6) ms after release")
    }
}
}
