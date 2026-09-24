import Foundation

/// User-facing insertion options (PARITY B2, B3, B6, B7, B8). Persisted in UserDefaults.
public struct InsertionSettings: Codable, Equatable, Sendable {
    public enum Method: String, Codable, CaseIterable, Sendable {
        /// Per-app strategy chain (Accessibility → paste → typing).
        case automatic
        /// Don't insert; only put the text on the clipboard (and in history).
        case clipboardOnly
        /// Pipe the text to a user script on stdin (e.g. custom tooling).
        case externalScript
    }

    public enum AutoSubmit: String, Codable, CaseIterable, Sendable {
        case off, enter, controlEnter, commandEnter
    }

    public var method: Method = .automatic
    /// Also leave the transcript on the clipboard after inserting (Handy's "copy to clipboard").
    public var copyToClipboard = false
    public var autoSubmit: AutoSubmit = .off
    public var appendTrailingSpace = false
    /// Wait before sending ⌘V (some apps need focus to settle).
    public var pasteDelayMs = 0
    public var externalScriptPath: String?

    public init() {}

    /// Missing keys take their defaults, so adding a setting never resets the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InsertionSettings()
        method = try c.decodeIfPresent(Method.self, forKey: .method) ?? d.method
        copyToClipboard = try c.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? d.copyToClipboard
        autoSubmit = try c.decodeIfPresent(AutoSubmit.self, forKey: .autoSubmit) ?? d.autoSubmit
        appendTrailingSpace = try c.decodeIfPresent(Bool.self, forKey: .appendTrailingSpace) ?? d.appendTrailingSpace
        pasteDelayMs = try c.decodeIfPresent(Int.self, forKey: .pasteDelayMs) ?? d.pasteDelayMs
        externalScriptPath = try c.decodeIfPresent(String.self, forKey: .externalScriptPath)
    }

    /// Text actually inserted, after formatting options.
    public func finalText(_ text: String) -> String {
        guard appendTrailingSpace, !text.isEmpty, text.last?.isWhitespace == false else { return text }
        return text + " "
    }

    public static let defaultsKey = "insertion.settings"

    public static func load(from defaults: UserDefaults = .standard) -> InsertionSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(InsertionSettings.self, from: data)
        else { return InsertionSettings() }
        return decoded
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
