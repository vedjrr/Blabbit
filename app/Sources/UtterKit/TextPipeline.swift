import Foundation
import UtterCore

/// Everything that shapes the text after transcription (Settings → Dictation).
public struct TextPipelineSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case exact, clean, code, professional, custom

        public var title: String {
            switch self {
            case .exact: "Exact"
            case .clean: "Clean"
            case .code: "Code"
            case .professional: "Professional"
            case .custom: "Custom"
            }
        }

        public var summary: String {
            switch self {
            case .exact: "As transcribed, with your vocabulary applied."
            case .clean: "Removes fillers like “um”, fixes capitals and full stops."
            case .code: "Keeps technical terms (JavaScript, JSON, PostgreSQL…); no added punctuation."
            case .professional: "Clean, then an AI processor improves grammar and tone (if you set one up)."
            case .custom: "Clean, then an AI processor follows your own instruction (if you set one up)."
            }
        }

        /// Modes that may use an AI processor after the local stages.
        public var usesProcessor: Bool { self == .professional || self == .custom }
    }

    public var mode: Mode = .clean
    public var removeFillers = true
    public var capitalize = true
    public var autoPunctuation = true
    public var spokenLineBreaks = true
    public var vocabulary: [String] = []
    public var vocabularyThreshold: Double = defaultVocabularyThreshold()
    /// Custom mode's instruction to the AI processor.
    public var customInstruction = "Rewrite this as a concise, friendly message."
    /// ISO language code, or nil for automatic detection.
    public var language: String?

    public init() {}

    public static let defaultsKey = "dictation.text"

    public static func load(from defaults: UserDefaults = .standard) -> TextPipelineSettings {
        guard let data = defaults.data(forKey: defaultsKey) else { return TextPipelineSettings() }
        return (try? JSONDecoder().decode(TextPipelineSettings.self, from: data)) ?? TextPipelineSettings()
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    // Tolerate settings saved by older builds (missing keys keep defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextPipelineSettings()
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? d.mode
        removeFillers = (try? c.decode(Bool.self, forKey: .removeFillers)) ?? d.removeFillers
        capitalize = (try? c.decode(Bool.self, forKey: .capitalize)) ?? d.capitalize
        autoPunctuation = (try? c.decode(Bool.self, forKey: .autoPunctuation)) ?? d.autoPunctuation
        spokenLineBreaks = (try? c.decode(Bool.self, forKey: .spokenLineBreaks)) ?? d.spokenLineBreaks
        vocabulary = (try? c.decode([String].self, forKey: .vocabulary)) ?? d.vocabulary
        vocabularyThreshold = (try? c.decode(Double.self, forKey: .vocabularyThreshold)) ?? d.vocabularyThreshold
        customInstruction = (try? c.decode(String.self, forKey: .customInstruction)) ?? d.customInstruction
        language = try? c.decode(String.self, forKey: .language)
    }

    var ffi: TextSettings {
        let m: TextMode = switch mode {
        case .exact: .exact
        case .clean: .clean
        case .code: .code
        case .professional: .professional
        case .custom: .custom
        }
        return TextSettings(mode: m, vocabulary: vocabulary, vocabularyThreshold: vocabularyThreshold,
                            removeFillers: removeFillers, capitalize: capitalize,
                            autoPunctuation: autoPunctuation, spokenLineBreaks: spokenLineBreaks)
    }

    /// Whisper models take the vocabulary as an initial prompt (M1: WER 0.161 → 0.032).
    public func initialPrompt(forModelFamily family: String?) -> String? {
        family == "whisper" ? vocabularyPrompt(vocabulary: vocabulary) : nil
    }
}

/// The result of running the pipeline on one transcript.
public struct PipelineResult: Equatable, Sendable {
    public var raw: String
    public var final: String
    /// Local changes (fillers, vocabulary corrections…), for the log and history.
    public var changes: [String]
    /// Which AI processor refined the text, if any.
    public var processor: String?
    /// Set when the AI step was wanted but failed; the local result was used.
    public var processorProblem: String?
}

/// Raw transcript → Rust stages → optional AI processor → final text (ADR-010).
public struct TextPipeline: Sendable {
    public var settings: TextPipelineSettings
    public var processor: (any TextProcessor)?

    public init(settings: TextPipelineSettings, processor: (any TextProcessor)? = nil) {
        self.settings = settings
        self.processor = processor
    }

    public static let professionalInstruction =
        "Improve the grammar, punctuation and readability of this dictated text without changing its meaning, facts, names or language. Keep the author's voice. Return only the rewritten text."

    public func run(_ raw: String) async -> PipelineResult {
        let local = processText(raw: raw, settings: settings.ffi)
        var result = PipelineResult(raw: raw, final: local.text, changes: local.changes)
        guard settings.mode.usesProcessor, let processor, !local.text.isEmpty else { return result }
        let instruction = settings.mode == .professional ? Self.professionalInstruction : settings.customInstruction
        do {
            let refined = try await processor.process(local.text, instruction: instruction, vocabulary: settings.vocabulary)
            let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.final = trimmed
                result.processor = processor.name
            }
        } catch {
            result.processorProblem = (error as? TextProcessorError)?.userMessage ?? "The AI processor failed, so the cleaned-up text was used."
            Log.error("text processor \(processor.name) failed: \(error)")
        }
        return result
    }
}
