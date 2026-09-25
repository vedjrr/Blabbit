import Foundation
import Testing
@testable import UtterKit

/// Real CoreAudio devices on this Mac (no capture is started).
@Suite(.serialized) struct AudioDeviceTests {
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

/// A device change mid-recording (AirPods connecting, a USB mic unplugged)
/// triggers the same handler as `AVAudioEngineConfigurationChange`.
@Suite(.serialized) struct DeviceChangeTests {
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
}
