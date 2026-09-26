import Foundation
import SayLessCore

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
    /// Saved instructions for Custom mode (PARITY D5); one is selected.
    public var prompts: [SavedPrompt] = SavedPrompt.starters
    public var selectedPromptID: String = SavedPrompt.starters[0].id

    public var selectedPrompt: SavedPrompt? { prompts.first { $0.id == selectedPromptID } ?? prompts.first }

    /// Custom mode's instruction to the AI processor: the selected prompt's.
    public var customInstruction: String {
        get { selectedPrompt?.instruction ?? SavedPrompt.starters[0].instruction }
        set {
            if let i = prompts.firstIndex(where: { $0.id == selectedPrompt?.id }) {
                prompts[i].instruction = newValue
            } else {
                let prompt = SavedPrompt(name: "My instruction", instruction: newValue)
                prompts.append(prompt)
                selectedPromptID = prompt.id
            }
        }
    }
    /// ISO language code, or nil for automatic detection.
    public var language: String?
    /// Whisper models only: output English whatever language is spoken.
    public var translateToEnglish = false

    public init() {}

    public static let defaultsKey = "dictation.text"

    public static func load(from defaults: UserDefaults = .standard) -> TextPipelineSettings {
        guard let data = defaults.data(forKey: defaultsKey) else { return TextPipelineSettings() }
        return (try? JSONDecoder().decode(TextPipelineSettings.self, from: data)) ?? TextPipelineSettings()
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, removeFillers, capitalize, autoPunctuation, spokenLineBreaks, vocabulary, vocabularyThreshold
        case customInstruction, prompts, selectedPromptID, language, translateToEnglish
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(removeFillers, forKey: .removeFillers)
        try c.encode(capitalize, forKey: .capitalize)
        try c.encode(autoPunctuation, forKey: .autoPunctuation)
        try c.encode(spokenLineBreaks, forKey: .spokenLineBreaks)
        try c.encode(vocabulary, forKey: .vocabulary)
        try c.encode(vocabularyThreshold, forKey: .vocabularyThreshold)
        try c.encode(customInstruction, forKey: .customInstruction) // read by older builds
        try c.encode(prompts, forKey: .prompts)
        try c.encode(selectedPromptID, forKey: .selectedPromptID)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(translateToEnglish, forKey: .translateToEnglish)
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
        if let prompts = try? c.decode([SavedPrompt].self, forKey: .prompts), !prompts.isEmpty {
            self.prompts = prompts
            selectedPromptID = (try? c.decode(String.self, forKey: .selectedPromptID)) ?? prompts[0].id
        } else if let old = try? c.decode(String.self, forKey: .customInstruction),
                  old != SavedPrompt.starters[0].instruction {
            // A build before saved prompts: its one instruction becomes the first prompt.
            let mine = SavedPrompt(id: "migrated", name: "My instruction", instruction: old)
            prompts = [mine] + SavedPrompt.starters
            selectedPromptID = mine.id
        }
        language = try? c.decode(String.self, forKey: .language)
        translateToEnglish = (try? c.decode(Bool.self, forKey: .translateToEnglish)) ?? false
    }

    func ffi(modelLanguages: [String] = []) -> TextSettings {
        let m: TextMode = switch mode {
        case .exact: .exact
        case .clean: .clean
        case .code: .code
        case .professional: .professional
        case .custom: .custom
        }
        return TextSettings(mode: m, vocabulary: vocabulary, vocabularyThreshold: vocabularyThreshold,
                            removeFillers: removeFillers, capitalize: capitalize,
                            autoPunctuation: autoPunctuation, spokenLineBreaks: spokenLineBreaks,
                            language: effectiveLanguage(forModelLanguages: modelLanguages.isEmpty ? nil : modelLanguages) ?? (modelLanguages.isEmpty ? language : nil),
                            modelLanguages: modelLanguages)
    }

    /// The chosen language if the model supports it, otherwise nil (auto-detect).
    /// "zh-Hans"/"zh-Hant" transcribe as "zh" and then convert the script.
    public func effectiveLanguage(forModelLanguages languages: [String]?) -> String? {
        guard let language, let languages else { return nil }
        let base = ChineseScript(languageCode: language) != nil ? "zh" : language
        return languages.contains(base) ? base : nil
    }

    /// The Chinese script to convert to (PARITY D7), when one was chosen.
    public var chineseScript: ChineseScript? { language.flatMap(ChineseScript.init(languageCode:)) }

    /// Whisper models take the vocabulary as an initial prompt, except Large v3
    /// Turbo, which measured worse with any prompt (0.043 → 0.129–0.157 WER over
    /// 6 clips, evidence/m5/vocabulary_wer.log); post-correction still applies.
    public static let modelsWithoutPrompt: Set<String> = ["whisper-large-v3-turbo"]

    public func initialPrompt(forModelFamily family: String?, modelID: String? = nil) -> String? {
        guard family == "whisper", !Self.modelsWithoutPrompt.contains(modelID ?? "") else { return nil }
        return vocabularyPrompt(vocabulary: vocabulary)
    }
}

/// Simplified ↔ Traditional Chinese (PARITY D7), with the system's ICU
/// transform: character by character, where Handy's OpenCC also swaps
/// regional phrasings (软件 → 軟件, not 軟體).
public enum ChineseScript: String, Sendable, CaseIterable {
    case simplified = "zh-Hans"
    case traditional = "zh-Hant"

    public init?(languageCode: String) { self.init(rawValue: languageCode) }

    public var title: String { self == .simplified ? "Chinese (Simplified)" : "Chinese (Traditional)" }

    public func convert(_ text: String) -> String {
        let transform = StringTransform(self == .simplified ? "Hant-Hans" : "Hans-Hant")
        return text.applyingTransform(transform, reverse: false) ?? text
    }
}

/// A named instruction for Custom mode.
public struct SavedPrompt: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var instruction: String

    public init(id: String = UUID().uuidString, name: String, instruction: String) {
        self.id = id
        self.name = name
        self.instruction = instruction
    }

    public static let starters: [SavedPrompt] = [
        SavedPrompt(id: "friendly", name: "Friendly message", instruction: "Rewrite this as a concise, friendly message."),
        SavedPrompt(id: "email", name: "Email", instruction: "Rewrite this as a clear, polite email body. Keep it short. No subject line, no signature."),
        SavedPrompt(id: "bullets", name: "Bullet points", instruction: "Turn this into short bullet points, one idea per line, each starting with \"- \"."),
        SavedPrompt(id: "prompt", name: "Prompt for an AI", instruction: "Rewrite this as a clear, specific prompt for an AI coding assistant. Keep every requirement; remove filler."),
    ]
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
    /// The model's languages: English-only clean-up (fillers) is skipped when
    /// the text is in another of them (PARITY D8).
    public var modelLanguages: [String]

    public init(settings: TextPipelineSettings, processor: (any TextProcessor)? = nil, modelLanguages: [String] = []) {
        self.settings = settings
        self.processor = processor
        self.modelLanguages = modelLanguages
    }

    public static let professionalInstruction =
        "Improve the grammar, punctuation and readability of this dictated text without changing its meaning, facts, names or language. Keep the author's voice. Return only the rewritten text."

    public func run(_ raw: String) async -> PipelineResult {
        var local = processText(raw: raw, settings: settings.ffi(modelLanguages: modelLanguages))
        if let script = settings.chineseScript {
            let converted = script.convert(local.text)
            if converted != local.text {
                local.text = converted
                local.changes.append("script: \(script.rawValue)")
            }
        }
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
