import CoreAudio
import IOKit
import Foundation

/// An audio input device as the Microphone menu shows it.
public struct AudioInputDevice: Equatable, Sendable {
    public var id: AudioDeviceID
    /// Stable across reconnects and reboots (what we persist).
    public var uid: String
    public var name: String
    public var isBluetooth: Bool
}

/// CoreAudio device queries. Safe from any thread.
public enum AudioDevices {
    /// The chosen input device's UID; nil means "follow the system default".
    public static let preferenceKey = "audio.inputDeviceUID"

    public static func inputDevices() -> [AudioInputDevice] { devices(scope: kAudioDevicePropertyScopeInput) }

    /// Devices that can play sound (for feedback sounds, PARITY A15).
    public static func outputDevices() -> [AudioInputDevice] { devices(scope: kAudioDevicePropertyScopeOutput) }

    public static func outputDevice(uid: String) -> AudioInputDevice? {
        outputDevices().first { $0.uid == uid }
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard channelCount(id, scope: scope) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType)
            let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            return AudioInputDevice(id: id, uid: uid, name: name, isBluetooth: bluetooth)
        }
    }

    public static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    public static func defaultInput() -> AudioInputDevice? {
        guard let id = defaultInputID() else { return nil }
        return inputDevices().first { $0.id == id }
    }

    public static func device(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
}

/// The device list for the menu, kept current by CoreAudio notifications on a
/// background queue, so opening the menu never waits on the HAL (which can
/// stall while a Bluetooth device connects).
public final class AudioDeviceCache: @unchecked Sendable {
    public static let shared = AudioDeviceCache()

    private let lock = NSLock()
    private var _devices: [AudioInputDevice] = []
    private var _defaultID: AudioDeviceID?
    private let queue = DispatchQueue(label: "dev.blabbit.audio-devices", qos: .utility)

    private init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let devices = AudioDevices.inputDevices()
        let defaultID = AudioDevices.defaultInputID()
        lock.lock()
        _devices = devices
        _defaultID = defaultID
        lock.unlock()
    }

    public var devices: [AudioInputDevice] { lock.lock(); defer { lock.unlock() }; return _devices }
    public var defaultDevice: AudioInputDevice? {
        lock.lock(); defer { lock.unlock() }
        return _devices.first { $0.id == _defaultID }
    }
}


/// Whether a laptop's lid is closed (IOKit `AppleClamshellState`). PARITY A14.
public enum Clamshell {
    public static func isClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// Desktops have no clamshell state at all.
    public static var isLaptop: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) != nil
    }
}
