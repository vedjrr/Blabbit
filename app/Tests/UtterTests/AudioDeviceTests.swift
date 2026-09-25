import Foundation
import Testing
@testable import UtterKit

/// Everything that touches the real audio hardware runs one test at a time
/// (nested suites inherit `.serialized`): parallel captures keep the device
/// running and would falsify the start-latency numbers.
@Suite(.serialized) enum AudioHardwareTests {}

/// Real CoreAudio devices on this Mac (no capture is started).
extension AudioHardwareTests { @Suite struct AudioDeviceTests {
    @Test func listsInputDevicesWithStableIDs() throws {
        let devices = AudioDevices.inputDevices()
        try #require(!devices.isEmpty, "no audio input device on this Mac")
        #expect(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
        #expect(Set(devices.map(\.uid)).count == devices.count)
        let fallback = try #require(AudioDevices.defaultInput())
        #expect(devices.contains(fallback))
        #expect(AudioDevices.device(uid: fallback.uid) == fallback)
        #expect(AudioDevices.device(uid: "no-such-device") == nil)
    }

    @Test func recorderUsesTheChosenDeviceAndFallsBack() throws {
        let queue = DispatchQueue(label: "dev.utter.test.audio")
        let recorder = AudioRecorder(queue: queue)
        let devices = AudioDevices.inputDevices()
        let chosen = try #require(devices.last)
        try queue.sync {
            try recorder.setPreferredDevice(uid: chosen.uid)
            #expect(recorder.activeDevice?.uid == chosen.uid)
            #expect(recorder.missingPreferredDevice == nil)
            // A device that is not connected (unplugged USB mic, AirPods away).
            try recorder.setPreferredDevice(uid: "unplugged-mic-uid")
            #expect(recorder.missingPreferredDevice == "unplugged-mic-uid")
            #expect(recorder.activeDevice?.uid == AudioDevices.defaultInput()?.uid)
            try recorder.setPreferredDevice(uid: nil)
            #expect(recorder.missingPreferredDevice == nil)
            #expect(recorder.activeDevice?.uid == AudioDevices.defaultInput()?.uid)
        }
    }
}

}

/// A device change mid-recording (AirPods connecting, a USB mic unplugged)
/// triggers the same handler as `AVAudioEngineConfigurationChange`.
extension AudioHardwareTests { @Suite struct DeviceChangeTests {
    @Test func recordingContinuesAcrossADeviceChange() throws {
        let queue = DispatchQueue(label: "dev.utter.test.audio-change")
        let recorder = AudioRecorder(queue: queue)
        do {
            try queue.sync { try recorder.start() }
        } catch {
            // No usable input for the test runner (e.g. microphone not allowed for this terminal).
            withKnownIssue("capture unavailable to the test runner: \(error)") { throw error }
            return
        }
        Thread.sleep(forTimeInterval: 0.4)
        queue.sync { recorder.simulateConfigurationChange() }
        #expect(recorder.isRecording, "capture carried on after the change")
        Thread.sleep(forTimeInterval: 0.4)
        let recording = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
        #expect(recording.interruptedByDeviceChange)
        #expect(recording.continuedOnDevice != nil)
        // ~0.8 s at 16 kHz on both sides of the change (callbacks keep coming even
        // when the input is silent or muted).
        #expect(recording.samples.count > 16_000 / 2, "got \(recording.samples.count) samples")
        #expect(recording.firstSampleNs != nil)
    }

    @Test func noDeviceToTakeOverKeepsTheAudioBeforeTheChange() throws {
        let queue = DispatchQueue(label: "dev.utter.test.audio-lost")
        let recorder = AudioRecorder(queue: queue)
        do { try queue.sync { try recorder.start() } } catch {
            withKnownIssue("capture unavailable to the test runner: \(error)") { throw error }
            return
        }
        Thread.sleep(forTimeInterval: 0.5)
        queue.sync {
            // The only microphone went away (USB mic unplugged, lid closed).
            recorder.defaultDevice = { nil }
            recorder.simulateConfigurationChange()
        }
        #expect(!recorder.isRecording)
        let lost = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
        #expect(lost.didRecord, "the dictation must not be dropped")
        #expect(lost.interruptedByDeviceChange && lost.continuedOnDevice == nil)
        #expect(lost.samples.count > 16_000 / 4, "kept \(lost.samples.count) samples from before the change")
        #expect(lost.firstSampleNs != nil)

        // The next recording starts clean (no stale "device changed" report).
        queue.sync { recorder.defaultDevice = AudioDevices.defaultInput }
        try queue.sync { try recorder.start() }
        Thread.sleep(forTimeInterval: 0.2)
        let next = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
        #expect(!next.interruptedByDeviceChange && next.continuedOnDevice == nil && next.didRecord)
    }

    @Test func choosingAMicrophoneMidRecordingWaitsForTheNextOne() throws {
        let queue = DispatchQueue(label: "dev.utter.test.audio-choose")
        let recorder = AudioRecorder(queue: queue)
        do { try queue.sync { try recorder.start() } } catch {
            withKnownIssue("capture unavailable to the test runner: \(error)") { throw error }
            return
        }
        Thread.sleep(forTimeInterval: 0.3)
        // A device other than the one capturing now, so the deferral is real.
        let current = queue.sync { recorder.activeDevice?.uid }
        guard let other = AudioDevices.inputDevices().first(where: { $0.uid != current }) else {
            withKnownIssue("only one input device on this Mac") { Issue.record("needs two input devices") }
            _ = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
            return
        }
        try queue.sync {
            try recorder.setPreferredDevice(uid: other.uid)
            try recorder.prepare() // what the menu handler calls: must not stop the capture
        }
        #expect(recorder.isRecording)
        Thread.sleep(forTimeInterval: 0.3)
        let recording = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
        #expect(recording.samples.count > 16_000 / 2, "capture kept going: \(recording.samples.count) samples")
        #expect(!recording.interruptedByDeviceChange)
        try queue.sync { try recorder.prepare() } // applied now, between recordings
        #expect(recorder.activeDevice?.uid == other.uid)
    }
}

}

/// G1 "key-down → recording < 50 ms": what the recorder itself costs, cold and warm.
extension AudioHardwareTests { @Suite struct CaptureStartLatencyTests {
    func startLatencies(recorder: AudioRecorder, queue: DispatchQueue, runs: Int) throws -> [(block: Double, firstSample: Double)] {
        var out: [(Double, Double)] = []
        for _ in 0..<runs {
            let (t0, t1): (UInt64, UInt64) = try queue.sync {
                let t0 = MonoClock.nowNs()
                try recorder.start()
                return (t0, MonoClock.nowNs())
            }
            Thread.sleep(forTimeInterval: 0.25)
            let recording = queue.sync { recorder.stop(releaseNs: MonoClock.nowNs()) }
            let first = recording.firstSampleNs.map { MonoClock.ms(from: t0, to: $0) } ?? .infinity
            out.append((MonoClock.ms(from: t0, to: t1), first))
            Thread.sleep(forTimeInterval: 1.0) // let the device go idle again
        }
        return out
    }

    @Test func coldStartIsMeasuredAndWarmStartIsInstant() throws {
        let queue = DispatchQueue(label: "dev.utter.test.latency")
        let recorder = AudioRecorder(queue: queue)
        do { try queue.sync { try recorder.prepare() } } catch {
            withKnownIssue("capture unavailable to the test runner: \(error)") { throw error }
            return
        }
        let cold = try startLatencies(recorder: recorder, queue: queue, runs: 5)
        try queue.sync { try recorder.setKeepReady(true) }
        Thread.sleep(forTimeInterval: 0.5) // let the pre-roll fill
        let warm = try startLatencies(recorder: recorder, queue: queue, runs: 5)
        let preRollCheck: Recording = try queue.sync {
            try recorder.start()
            return recorder.stop(releaseNs: MonoClock.nowNs())
        }
        try queue.sync { try recorder.setKeepReady(false) }
        let fmt = { (xs: [(block: Double, firstSample: Double)]) in xs.map { String(format: "%.1f/%.1f", $0.block, $0.firstSample) }.joined(separator: " ") }
        Log.info("capture_start_latency_ms cold(block/first_sample)=\(fmt(cold)) warm=\(fmt(warm))")
        print("capture_start_latency_ms cold(block/first_sample)=\(fmt(cold)) warm=\(fmt(warm))")
        // Cold: the device start (~40–65 ms here) is recorded, not asserted.
        #expect(cold.allSatisfy { $0.firstSample < 500 })
        // Warm: audio is in hand at once, far inside the 50 ms budget.
        #expect(warm.allSatisfy { $0.block < 10 && $0.firstSample < 10 }, "warm \(fmt(warm))")
        // The pre-roll (0.15 s before the start) is part of the recording.
        #expect(preRollCheck.samples.count >= Int(16_000 * AudioRecorder.preRollSeconds * 0.8), "pre-roll samples \(preRollCheck.samples.count)")
    }
}
}
