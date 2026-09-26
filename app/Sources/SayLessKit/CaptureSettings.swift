import Foundation

/// Settings → Audio options that shape the recording itself.
public struct CaptureSettings: Codable, Equatable, Sendable {
    /// 0-based input channel; nil averages all channels (PARITY A13).
    public var inputChannel: Int?
    /// Microphone to use while a laptop's lid is closed (PARITY A14).
    public var clamshellDeviceUID: String?
    /// Keep recording this long after release, so the last word isn't cut (PARITY A17).
    public var extraBufferMs = 0
    /// Keep the input open 30 s after a dictation so the next starts warm (PARITY F21).
    public var lazyClose = false
    /// Remove long silences before transcription (PARITY A16). On by default, like Handy's VAD.
    public var trimSilence = true

    public static let extraBufferRange = 0...1000

    public init() {}

    public static let defaultsKey = "audio.capture"

    public static func load(from defaults: UserDefaults = .standard) -> CaptureSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(CaptureSettings.self, from: data) else { return CaptureSettings() }
        return saved
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureSettings()
        inputChannel = try c.decodeIfPresent(Int.self, forKey: .inputChannel)
        clamshellDeviceUID = try c.decodeIfPresent(String.self, forKey: .clamshellDeviceUID)
        let buffer = try c.decodeIfPresent(Int.self, forKey: .extraBufferMs) ?? d.extraBufferMs
        extraBufferMs = min(max(buffer, Self.extraBufferRange.lowerBound), Self.extraBufferRange.upperBound)
        lazyClose = try c.decodeIfPresent(Bool.self, forKey: .lazyClose) ?? d.lazyClose
        trimSilence = try c.decodeIfPresent(Bool.self, forKey: .trimSilence) ?? d.trimSilence
    }
}
