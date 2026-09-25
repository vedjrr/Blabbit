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

    /// What spoken line breaks ("new line") become when inserted.
    public enum Newlines: String, Codable, CaseIterable, Sendable {
        /// Real line breaks.
        case keep
        /// Spaces: for chat apps where Return sends the message.
        case spaces
    }

    public var method: Method = .automatic
    /// Also leave the transcript on the clipboard after inserting (Handy's "copy to clipboard").
    public var copyToClipboard = false
    public var autoSubmit: AutoSubmit = .off
    public var appendTrailingSpace = false
    /// Wait before sending ⌘V (some apps need focus to settle).
    public var pasteDelayMs = 0
    /// Minimum wait after pasting before the clipboard is restored.
    public var pasteDelayAfterMs = 0
    public var externalScriptPath: String?
    /// Restore the previous clipboard after a paste.
    public var restoreClipboard = true
    public var newlines: Newlines = .keep

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
        pasteDelayAfterMs = try c.decodeIfPresent(Int.self, forKey: .pasteDelayAfterMs) ?? d.pasteDelayAfterMs
        externalScriptPath = try c.decodeIfPresent(String.self, forKey: .externalScriptPath)
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        newlines = try c.decodeIfPresent(Newlines.self, forKey: .newlines) ?? d.newlines
    }

    /// Text actually inserted, after formatting options.
    public func finalText(_ text: String) -> String {
        var text = text
        if newlines == .spaces {
            text = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
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
