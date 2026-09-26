import Foundation

/// Typing as you speak: each phrase is typed into the app at the pause after
/// it, while the user keeps talking; on release only the last phrase is left.
public enum LiveTypingPolicy {
    /// Whether a dictation types as it's spoken. AI modes need the whole text
    /// first; Whisper pads every call to a 30 s window, so short phrases would
    /// each cost a full window; slow models can't keep up.
    public static func applies(settings: InsertionSettings, mode: TextPipelineSettings.Mode,
                               family: String?, measuredRTF: Double?) -> Bool {
        guard settings.typeWhileSpeaking, settings.method == .automatic, !mode.usesProcessor,
              family != "whisper", let rtf = measuredRTF else { return false }
        return LivePreviewPolicy.windowSeconds(measuredRTF: rtf) != nil
    }

    /// What goes between the text already typed and the next phrase: a space,
    /// except at the start, around line breaks, and between CJK characters.
    public static func separator(after typed: String, before next: String) -> String {
        guard let last = typed.last, let first = next.first else { return "" }
        if last.isWhitespace || first.isWhitespace { return "" }
        let joined = IncrementalTranscriber.join([String(last), String(first)])
        return joined.count > 2 ? " " : ""
    }

    /// The phrases that weren't typed while speaking (in order), then the tail.
    public static func remainder(segments: [String], typed: Set<Int>, tail: String) -> String {
        let left = segments.indices.filter { !typed.contains($0) }.map { segments[$0] } + [tail]
        return IncrementalTranscriber.join(left.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Phrases are cleaned up like the whole text, except the full stop,
    /// which only the end of the dictation gets.
    public static func partSettings(_ settings: TextPipelineSettings) -> TextPipelineSettings {
        var settings = settings
        settings.autoPunctuation = false
        return settings
    }
}

/// One dictation's phrases typed while the user is still speaking. Main actor only.
@MainActor
final class LiveTypingSession {
    let serial: Int
    let partSettings: TextPipelineSettings
    let languages: [String]
    /// Segment indices whose text went in.
    private(set) var typedIndices: Set<Int> = []
    /// Exactly what was typed so far, separators included.
    private(set) var typedText = ""
    /// A phrase was blocked or failed: the rest waits for the release, which
    /// tries again (and handles a password field the usual way).
    var stopped = false
    /// A phrase may or may not have gone in: the whole text goes on the clipboard at the end.
    var unverified = false
    var lastReport: InsertReport?
    /// Phrases are typed one after another.
    var chain: Task<Void, Never>?

    init(serial: Int, settings: TextPipelineSettings, languages: [String]) {
        self.serial = serial
        partSettings = LiveTypingPolicy.partSettings(settings)
        self.languages = languages
    }

    func recordTyped(index: Int, inserted: String) {
        typedIndices.insert(index)
        typedText += inserted
    }
}
