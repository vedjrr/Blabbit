//! Text pipeline (ADR-010): `raw transcript → [stages] → final text`.
//!
//! Every stage is a pure function over a string, tested on its own. Modes pick
//! which stages run. Exact, Clean and Code never need an LLM; Professional and
//! Custom run the Clean stages here and may then be refined by an optional
//! `TextProcessor` in the app.
use rphonetic::{DoubleMetaphone, Encoder};
use strsim::jaro_winkler;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// As transcribed: spacing and personal vocabulary only.
    Exact,
    /// Fillers and stutters removed, sentences capitalised and punctuated.
    Clean,
    /// Developer text: fillers removed, technical terms fixed, no added punctuation.
    Code,
    /// Clean here; grammar and tone by an optional AI processor in the app.
    Professional,
    /// Clean here; the user's instruction by an optional AI processor in the app.
    Custom,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TextOptions {
    pub mode: Mode,
    /// Personal vocabulary (e.g. "HoldMyCode", "PostgreSQL").
    pub vocabulary: Vec<String>,
    /// 0…1; higher means fewer, surer vocabulary corrections.
    pub vocabulary_threshold: f64,
    pub remove_fillers: bool,
    pub capitalize: bool,
    /// Adds a final full stop when the text has none.
    pub auto_punctuation: bool,
    /// Spoken "new line" / "new paragraph" become line breaks.
    pub spoken_line_breaks: bool,
    /// The language the user chose (ISO 639-1), if any.
    pub language: Option<String>,
    /// What the model can output; detection picks among these.
    pub model_languages: Vec<String>,
}

impl Default for TextOptions {
    fn default() -> Self {
        TextOptions {
            mode: Mode::Clean,
            vocabulary: Vec::new(),
            vocabulary_threshold: DEFAULT_THRESHOLD,
            remove_fillers: true,
            capitalize: true,
            auto_punctuation: true,
            language: None,
            model_languages: Vec::new(),
            spoken_line_breaks: true,
        }
    }
}

pub const DEFAULT_THRESHOLD: f64 = 0.88;

/// Result plus what changed, for the log and the history view.
#[derive(Debug, Clone, PartialEq)]
pub struct Processed {
    pub text: String,
    /// e.g. `vocabulary: "hold my code" → "HoldMyCode"`.
    pub changes: Vec<String>,
}

pub fn process(raw: &str, options: &TextOptions) -> Processed {
    let mut changes = Vec::new();
    let mut text = normalize_spacing(raw);
    let clean_like = matches!(options.mode, Mode::Clean | Mode::Professional | Mode::Custom);
    let code = options.mode == Mode::Code;

    // The filler list is English: "um" is a German word ("around") and "er" means
    // "he", so other languages keep them (PARITY D8).
    let english = output_language(&text, options).is_none_or(|l| l == "en");
    if (clean_like || code) && options.remove_fillers && english {
        let before = text.clone();
        text = remove_fillers(&text);
        text = remove_stutters(&text);
        if text != before {
            changes.push("fillers".into());
        }
    }
    if (clean_like || code) && options.spoken_line_breaks {
        text = spoken_line_breaks(&text);
    }
    let mut vocabulary = options.vocabulary.clone();
    if code {
        vocabulary.extend(CODE_TERMS.iter().map(|s| s.to_string()));
    }
    if !vocabulary.is_empty() {
        let (corrected, fixes) = apply_vocabulary(&text, &vocabulary, options.vocabulary_threshold);
        text = corrected;
        changes.extend(fixes);
    }
    if clean_like {
        if options.capitalize {
            text = capitalize_sentences(&text);
        }
        if options.auto_punctuation {
            text = ensure_final_punctuation(&text);
        }
    }
    Processed { text: normalize_spacing(&text), changes }
}

// MARK: Stages

/// Single spaces, none before punctuation, none at the ends of lines.
pub fn normalize_spacing(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for (i, line) in text.split('\n').enumerate() {
        if i > 0 {
            out.push('\n');
        }
        let words: Vec<&str> = line.split_whitespace().collect();
        let mut joined = String::new();
        for word in words {
            let attaches = word.chars().all(|c| matches!(c, ',' | '.' | '!' | '?' | ';' | ':'));
            if !joined.is_empty() && !attaches {
                joined.push(' ');
            }
            joined.push_str(word);
        }
        out.push_str(&joined);
    }
    out
}

/// The language the text is in: the user's choice, the model's only language,
/// or a confident detection among the model's languages (None when unsure).
pub fn output_language(text: &str, options: &TextOptions) -> Option<String> {
    if let Some(language) = &options.language {
        return Some(language.clone());
    }
    match options.model_languages.as_slice() {
        [] => None,
        [only] => Some(only.clone()),
        many => detect_language(text, many),
    }
}

/// Minimum whatlang confidence, on top of its own reliability check: a wrong
/// language would keep fillers in English text, so unsure means None.
const MIN_CONFIDENCE: f64 = 0.5;

/// Detects which of `candidates` (ISO 639-1) the text is written in.
pub fn detect_language(text: &str, candidates: &[String]) -> Option<String> {
    let allow: Vec<whatlang::Lang> = candidates.iter().filter_map(|c| lang_for_code(c)).collect();
    if allow.is_empty() || text.split_whitespace().count() < 3 {
        return None;
    }
    let info = whatlang::Detector::with_allowlist(allow).detect(text)?;
    if !info.is_reliable() || info.confidence() < MIN_CONFIDENCE {
        return None;
    }
    code_for_lang(info.lang()).map(str::to_string)
}

const LANG_CODES: &[(&str, whatlang::Lang)] = {
    use whatlang::Lang::*;
    &[
        ("en", Eng), ("de", Deu), ("fr", Fra), ("es", Spa), ("it", Ita), ("pt", Por), ("nl", Nld), ("pl", Pol),
        ("ru", Rus), ("uk", Ukr), ("cs", Ces), ("sk", Slk), ("sl", Slv), ("hr", Hrv), ("bg", Bul), ("ro", Ron),
        ("hu", Hun), ("fi", Fin), ("sv", Swe), ("da", Dan), ("et", Est), ("lv", Lav), ("lt", Lit), ("el", Ell),
        ("zh", Cmn), ("ja", Jpn), ("ko", Kor), ("tr", Tur), ("ar", Ara), ("he", Heb), ("hi", Hin), ("nb", Nob),
        ("no", Nob), ("id", Ind), ("vi", Vie), ("th", Tha), ("fa", Pes), ("ca", Cat), ("sr", Srp), ("be", Bel),
    ]
};

fn lang_for_code(code: &str) -> Option<whatlang::Lang> {
    let base = code.split(['-', '_']).next().unwrap_or(code).to_ascii_lowercase();
    LANG_CODES.iter().find(|(c, _)| *c == base).map(|(_, l)| *l)
}

fn code_for_lang(lang: whatlang::Lang) -> Option<&'static str> {
    LANG_CODES.iter().find(|(_, l)| *l == lang).map(|(c, _)| *c)
}

const FILLERS: &[&str] = &["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm", "mhm"];

fn bare(word: &str) -> String {
    word.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase()
}

/// Drops filler words ("um", "uh", "erm"…) with the comma that follows them.
pub fn remove_fillers(text: &str) -> String {
    let lines: Vec<String> = text
        .split('\n')
        .map(|line| {
            let mut kept: Vec<String> = Vec::new();
            for word in line.split_whitespace() {
                // "ER" (all capitals) is a word, not a filler.
                let core = word.trim_matches(|c: char| !c.is_alphanumeric());
                let shouted = core.len() > 1 && core.chars().all(|c| c.is_uppercase());
                if FILLERS.contains(&bare(word).as_str()) && !shouted {
                    // Keep sentence-ending punctuation the filler carried ("…the end, um.").
                    if let Some(end) = word.chars().last().filter(|c| matches!(c, '.' | '!' | '?')) {
                        if let Some(last) = kept.last_mut() {
                            let trimmed = last.trim_end_matches(',').to_string();
                            *last = format!("{trimmed}{end}");
                        }
                    }
                    continue;
                }
                kept.push(word.to_string());
            }
            kept.join(" ")
        })
        .collect();
    lines.join("\n")
}

/// Words people stutter on ("I I think", "the the") lose the repeat. Only
/// these: a repeated number ("1 1 2 3", "one one two") or "had had" is meaning.
pub fn remove_stutters(text: &str) -> String {
    const STBLABBIT: &[&str] = &[
        "i", "a", "an", "the", "to", "and", "we", "it", "in", "of", "on", "you", "my", "but", "for", "with", "at", "is", "he", "she", "they",
    ];
    let mut out: Vec<&str> = Vec::new();
    for word in text.split(' ') {
        if let Some(prev) = out.last() {
            let (a, b) = (bare(prev), bare(word));
            let prev_open = !prev.ends_with(|c: char| matches!(c, ',' | '.' | '!' | '?' | ';' | ':'));
            if prev_open && !a.is_empty() && a == b && STBLABBIT.contains(&a.as_str()) {
                // Keep the second copy's punctuation: "the the." → "the."
                out.pop();
            }
        }
        out.push(word);
    }
    out.join(" ")
}

/// "new paragraph" → blank line, "new line" → line break (spoken commands).
/// Only at a clause boundary (after punctuation, at the start or end, or with
/// punctuation of its own), so "a new line of products" stays ordinary speech.
pub fn spoken_line_breaks(text: &str) -> String {
    let mut out = String::new();
    let words: Vec<&str> = text.split(' ').collect();
    let mut i = 0;
    while i < words.len() {
        let pair = (words.get(i).map(|w| bare(w)), words.get(i + 1).map(|w| bare(w)));
        let command = match (pair.0.as_deref(), pair.1.as_deref()) {
            (Some("new"), Some("paragraph")) => Some("\n\n"),
            (Some("new"), Some("line")) => Some("\n"),
            _ => None,
        };
        // Its own clause: after the start or a clause end ("…, new line, …",
        // "Done. New paragraph"), so "we launched a new line." stays a sentence.
        let at_boundary = i == 0 || words.get(i - 1).is_some_and(|w| ends_clause(w));
        if let (Some(brk), true) = (command, at_boundary) {
            // Punctuation said around the command belongs to the previous sentence.
            let trimmed = out.trim_end_matches([' ', ',']).to_string();
            out = trimmed + brk;
            i += 2;
            continue;
        }
        if !out.is_empty() && !out.ends_with('\n') {
            out.push(' ');
        }
        out.push_str(words[i]);
        i += 1;
    }
    out
}

/// Upper-cases the first letter of each sentence and the pronoun "i".
pub fn capitalize_sentences(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut start = true;
    for word in text.split_inclusive([' ', '\n']) {
        let core = word.trim_end_matches([' ', '\n']);
        let mut w = word.to_string();
        let lone_i = bare(core) == "i" || bare(core).starts_with("i'") || bare(core).starts_with("i\u{2019}");
        if lone_i {
            // Replace the 'i' itself, wherever it sits ("(i", "“i", "😀i").
            if let Some((pos, _)) = w.char_indices().find(|(_, c)| *c == 'i') {
                w.replace_range(pos..pos + 1, "I");
            }
        } else if start {
            if let Some((pos, c)) = w.char_indices().find(|(_, c)| c.is_alphabetic()) {
                if c.is_lowercase() {
                    let upper: String = c.to_uppercase().collect();
                    w.replace_range(pos..pos + c.len_utf8(), &upper);
                }
            }
        }
        if core.chars().any(|c| c.is_alphanumeric()) {
            start = false;
        }
        if core.ends_with(['.', '!', '?']) || word.ends_with('\n') {
            start = true;
        }
        out.push_str(&w);
    }
    out
}

/// Adds a full stop at the end of each paragraph that ends in a word.
pub fn ensure_final_punctuation(text: &str) -> String {
    text.split('\n')
        .map(|line| {
            let trimmed = line.trim_end();
            match trimmed.chars().last() {
                Some(c) if c.is_alphanumeric() => format!("{trimmed}."),
                Some(',') | Some(';') => format!("{}.", trimmed.trim_end_matches([',', ';'])),
                _ => trimmed.to_string(),
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

// MARK: Vocabulary

/// Well-known developer terms used in Code mode (in addition to the user's).
/// Words that are also ordinary English ("rust", "python") are left out: Code
/// mode must not rewrite normal speech.
pub const CODE_TERMS: &[&str] = &[
    "JavaScript", "TypeScript", "PostgreSQL", "MySQL", "SQLite", "GitHub", "GitLab", "JSON", "YAML", "HTTP", "HTTPS",
    "API", "iOS", "macOS", "Xcode", "SwiftUI", "UIKit", "AppKit", "Kubernetes", "Node.js", "npm", "OAuth",
    "GraphQL", "WebSocket", "localhost", "README", "CLI", "SDK", "URL", "CSS", "HTML",
];

/// Short function words: a phrase containing one is usually an ordinary
/// phrase ("the script", "type the script"), so it needs a near-certain match.
const FUNCTION_WORDS: &[&str] = &[
    "the", "a", "an", "to", "of", "in", "on", "at", "and", "or", "for", "with", "is", "it", "my", "your", "our", "this", "that",
];
const FUNCTION_WORD_THRESHOLD: f64 = 0.96;

fn letters(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// Double Metaphone codes, only for plain ASCII letters: the encoder slices
/// by byte and panics inside multi-byte characters ("café", "Ü"), and its
/// rules are English anyway.
fn phonetic(letters: &str) -> Option<(String, String)> {
    if letters.is_empty() || !letters.is_ascii() {
        return None;
    }
    let metaphone = DoubleMetaphone::new(None);
    Some((metaphone.encode(letters), metaphone.encode_alternate(letters)))
}

/// A vocabulary term with its comparison keys computed once per call.
struct TermKey<'a> {
    term: &'a str,
    letters: String,
    codes: Option<(String, String)>,
}

impl<'a> TermKey<'a> {
    fn new(term: &'a str) -> Self {
        let letters = letters(term);
        let codes = phonetic(&letters);
        TermKey { term, letters, codes }
    }

    /// Short terms only fix casing ("json" → "JSON"); terms with symbols
    /// ("C#", "C++") can't be matched by letters alone and are skipped.
    fn usable(&self) -> bool {
        !self.letters.is_empty() && (self.letters.len() >= 4 || self.term.chars().all(|c| c.is_alphanumeric() || c == '.'))
    }
}

/// How well a spoken phrase matches a vocabulary term (0…1), or None if it
/// shouldn't be considered at all.
pub fn match_score(phrase: &str, term: &str) -> Option<f64> {
    let key = TermKey::new(term);
    let p = letters(phrase);
    match_details(&p, &mut None, &key).map(|(score, _)| score)
}

/// Score plus whether the phrase sounds like the term. `phrase_codes` caches
/// the phrase's phonetic codes across terms.
fn match_details(p: &str, phrase_codes: &mut Option<Option<(String, String)>>, key: &TermKey) -> Option<(f64, bool)> {
    let t = &key.letters;
    if !key.usable() {
        return None;
    }
    if p.len() < 4 || t.len() < 4 {
        return (p == t.as_str() && !p.is_empty()).then_some((1.0, true));
    }
    if p == t {
        return Some((1.0, true));
    }
    // Different lengths mean different words ("swift" vs "SwiftUI", "type" vs "TypeScript").
    let ratio = p.chars().count() as f64 / t.chars().count() as f64;
    if !(0.75..=1.34).contains(&ratio) {
        return None;
    }
    let similarity = jaro_winkler(p, t);
    let codes = phrase_codes.get_or_insert_with(|| phonetic(p));
    let sounds_alike = match (codes.as_ref(), key.codes.as_ref()) {
        (Some((pp, pa)), Some((tp, ta))) => pp == tp || pa == ta,
        _ => false,
    };
    // Sounding alike earns a lower bar ("Manuth" ~ "Maynooth").
    Some((if sounds_alike { similarity + 0.08 } else { similarity }, sounds_alike))
}

/// A single lower-case word is probably an ordinary dictionary word
/// ("swiftly"); mixed case or digits ("postGirSQL", "blabbit1") are not.
fn looks_like_plain_word(word: &str) -> bool {
    let core = word.trim_matches(|c: char| !c.is_alphanumeric());
    let mut chars = core.chars();
    let first_ok = chars.next().is_some_and(|c| c.is_alphabetic());
    first_ok && chars.all(|c| c.is_lowercase())
}

fn ends_clause(word: &str) -> bool {
    word.ends_with(|c: char| matches!(c, ',' | '.' | '!' | '?' | ';' | ':'))
}

/// Replaces 1–3 word phrases that match a vocabulary term, best matches first,
/// never across sentence punctuation. Returns the text and the changes made.
pub fn apply_vocabulary(text: &str, vocabulary: &[String], threshold: f64) -> (String, Vec<String>) {
    let keys: Vec<TermKey> = vocabulary.iter().map(|t| TermKey::new(t)).filter(TermKey::usable).collect();
    let term_letters: Vec<&str> = keys.iter().map(|k| k.letters.as_str()).collect();
    let mut changes = Vec::new();
    let lines: Vec<String> = text
        .split('\n')
        .map(|line| {
            let words: Vec<&str> = line.split(' ').filter(|w| !w.is_empty()).collect();
            // (score, start, len, term)
            let mut candidates: Vec<(f64, usize, usize, &str)> = Vec::new();
            for start in 0..words.len() {
                for len in 1..=3.min(words.len() - start) {
                    let span = &words[start..start + len];
                    // A phrase may end with punctuation but not contain it inside.
                    if span[..len - 1].iter().any(|w| ends_clause(w)) {
                        break;
                    }
                    let bares: Vec<String> = span.iter().map(|w| bare(w)).collect();
                    // A word already spelled as a term stays itself ("the TypeScript").
                    if len > 1 && bares.iter().any(|b| term_letters.contains(&letters(b).as_str())) {
                        continue;
                    }
                    let has_function_word = len > 1 && bares.iter().any(|b| FUNCTION_WORDS.contains(&b.as_str()));
                    let needed = if has_function_word { threshold.max(FUNCTION_WORD_THRESHOLD) } else { threshold };
                    let phrase = letters(&span.join(" "));
                    let mut phrase_codes = None;
                    let as_written = span.iter().map(|w| w.trim_matches(|c: char| !c.is_alphanumeric())).collect::<Vec<_>>().join(" ");
                    for key in &keys {
                        let Some((score, sounds_alike)) = match_details(&phrase, &mut phrase_codes, key) else { continue };
                        // A real-looking single word must also sound like the term.
                        if len == 1 && score < 1.0 && looks_like_plain_word(span[0]) && !sounds_alike {
                            continue;
                        }
                        // Already written exactly as the term: nothing to do.
                        if score >= needed && as_written != key.term {
                            candidates.push((score + len as f64 * 0.001, start, len, key.term));
                        }
                    }
                }
            }
            candidates.sort_by(|a, b| b.0.total_cmp(&a.0));
            let mut taken = vec![false; words.len()];
            let mut replacement: Vec<Option<(usize, String)>> = vec![None; words.len()];
            for (_, start, len, term) in candidates {
                if taken[start..start + len].iter().any(|t| *t) {
                    continue;
                }
                taken[start..start + len].iter_mut().for_each(|t| *t = true);
                let last = words[start + len - 1];
                let lead: String = words[start].chars().take_while(|c| !c.is_alphanumeric()).collect();
                let trail: String = last.chars().rev().take_while(|c| !c.is_alphanumeric()).collect::<Vec<_>>().into_iter().rev().collect();
                changes.push(format!("vocabulary: \"{}\" → \"{term}\"", words[start..start + len].join(" ")));
                replacement[start] = Some((len, format!("{lead}{term}{trail}")));
            }
            let mut out = Vec::new();
            let mut i = 0;
            while i < words.len() {
                if let Some((len, text)) = &replacement[i] {
                    out.push(text.clone());
                    i += len;
                } else {
                    out.push(words[i].to_string());
                    i += 1;
                }
            }
            out.join(" ")
        })
        .collect();
    (lines.join("\n"), changes)
}

/// Whisper's initial prompt: the user's terms in a plain sentence bias decoding
/// towards their spelling. A sentence works better than a bare list, which
/// Whisper tends to imitate by gluing words together (evidence/m5/vocabulary_wer.log:
/// Whisper Small 0.057 with a list vs 0.029 as a sentence, over 6 clips).
pub fn whisper_prompt(vocabulary: &[String]) -> Option<String> {
    let terms: Vec<&str> = vocabulary.iter().map(|s| s.trim()).filter(|s| !s.is_empty()).take(40).collect();
    match terms.as_slice() {
        [] => None,
        [one] => Some(format!("We talked about {one}.")),
        [rest @ .., last] => Some(format!("We talked about {} and {last}.", rest.join(", "))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vocab() -> Vec<String> {
        ["HoldMyCode", "Decivra", "Maynooth", "PostgreSQL", "TypeScript", "SwiftUI", "WhisperKit"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    }

    fn opts(mode: Mode) -> TextOptions {
        TextOptions { mode, vocabulary: vocab(), ..TextOptions::default() }
    }

    #[test]
    fn spacing() {
        assert_eq!(normalize_spacing("  hello   world ,  ok .  "), "hello world, ok.");
        assert_eq!(normalize_spacing("a  b\n  c "), "a b\nc");
    }

    #[test]
    fn fillers_only_come_out_of_english() {
        let langs: Vec<String> = ["en", "de", "fr", "es"].iter().map(|s| s.to_string()).collect();
        let mut o = TextOptions { model_languages: langs.clone(), ..TextOptions::default() };
        // German: "um" (around) and "er" (he) are words.
        let german = "ich komme um drei Uhr und er bringt den Kuchen mit, das wird schön";
        assert_eq!(detect_language(german, &langs).as_deref(), Some("de"));
        assert!(process(german, &o).text.contains("um drei Uhr und er bringt"));
        // English with the same model: fillers go.
        let english = "um so I think we should uh ship the new settings window on Friday";
        assert_eq!(detect_language(english, &langs).as_deref(), Some("en"));
        assert!(!process(english, &o).text.to_lowercase().contains(" uh "));
        // The user's chosen language wins over detection.
        o.language = Some("de".into());
        assert!(process(english, &o).text.contains("uh"));
        // An English-only model, or no model info: fillers go, as before.
        let en_only = TextOptions { model_languages: vec!["en".into()], ..TextOptions::default() };
        assert_eq!(process("um hello there", &en_only).text, "Hello there.");
        assert_eq!(process("um hello there", &TextOptions::default()).text, "Hello there.");
        // Too short to tell: unsure, so English behaviour.
        assert_eq!(detect_language("um ok", &langs), None);
    }

    #[test]
    fn fillers_and_stutters() {
        assert_eq!(remove_fillers("So, um, I think uh we should"), "So, I think we should");
        assert_eq!(remove_fillers("Um, we should go"), "we should go");
        assert_eq!(remove_fillers("that is the end, um."), "that is the end.");
        assert_eq!(remove_fillers("Umbrella and hummus"), "Umbrella and hummus");
        assert_eq!(remove_stutters("I I think the the plan works"), "I think the plan works");
        assert_eq!(remove_stutters("no no no, that that works"), "no no no, that that works");
        // Repeated numbers and real repeats are meaning, not stutters.
        assert_eq!(remove_stutters("my pin is 1 1 2 3"), "my pin is 1 1 2 3");
        assert_eq!(remove_stutters("call extension one one two"), "call extension one one two");
        assert_eq!(remove_stutters("i had had enough"), "i had had enough");
        assert_eq!(remove_fillers("er, the ER doctor"), "the ER doctor");
        assert_eq!(remove_stutters("it is. Is it"), "it is. Is it");
    }

    #[test]
    fn capitalisation_and_punctuation() {
        assert_eq!(capitalize_sentences("hello there. how are you? i'm fine"), "Hello there. How are you? I'm fine");
        assert_eq!(capitalize_sentences("first line\nsecond line"), "First line\nSecond line");
        assert_eq!(ensure_final_punctuation("done"), "done.");
        assert_eq!(ensure_final_punctuation("done?"), "done?");
        assert_eq!(ensure_final_punctuation("a,\nb"), "a.\nb.");
    }

    #[test]
    fn spoken_commands() {
        assert_eq!(spoken_line_breaks("first point. New line. Second point"), "first point.\nSecond point");
        assert_eq!(spoken_line_breaks("intro, new paragraph, body"), "intro\n\nbody");
        assert_eq!(spoken_line_breaks("thanks. New line"), "thanks.\n");
        assert_eq!(spoken_line_breaks("that was a new line."), "that was a new line.");
        assert_eq!(spoken_line_breaks("i said new line"), "i said new line");
        // Ordinary speech is left alone.
        assert_eq!(spoken_line_breaks("we launched a new line of products"), "we launched a new line of products");
        assert_eq!(spoken_line_breaks("start a new paragraph about cats"), "start a new paragraph about cats");
    }

    #[test]
    fn vocabulary_fixes_real_mishearings() {
        // Real outputs from the fixture runs (evidence/m3/model_verification.log).
        let cases = [
            ("Testing udder, 123, hold my code uses post gur SQL.", "HoldMyCode uses PostgreSQL."),
            ("Testing Udder, 123, hold my code uses postGirSQL.", "HoldMyCode uses PostgreSQL."),
            ("hold my code uses post-ger SQL", "HoldMyCode uses PostgreSQL"),
            ("I studied computer science at Manooth before", "at Maynooth before"),
            ("I studied computer science at Manuth before", "at Maynooth before"),
            ("moved the backend to type script.", "to TypeScript."),
            ("moved the back end the TypeScript.", "the TypeScript."),
            ("the settings screen in swift UI and", "in SwiftUI and"),
            ("built with whisper kit on device", "built with WhisperKit on"),
            ("I work at decivra now", "at Decivra now"),
            ("we use postgresql and typescript", "we use PostgreSQL and TypeScript"),
        ];
        for (input, expected) in cases {
            let (out, _) = apply_vocabulary(input, &vocab(), DEFAULT_THRESHOLD);
            assert!(out.contains(expected), "{input:?} → {out:?} (wanted {expected:?})");
        }
    }

    #[test]
    fn vocabulary_leaves_ordinary_words_alone() {
        let untouched = [
            "The quick brown fox jumps over the lazy dog while the band plays in the park.",
            "Please schedule a meeting with the design team for next Tuesday afternoon at three.",
            "I need to type the script in swift and post it to my code review.",
            "The minute he held my cup, the whisper stopped.",
            "Swift is fast. Type safety matters.",
            "She swiftly left the room.",
            // Known trade-off: "hold my coat" vs HoldMyCode is close enough to change
            // (score ≥ 0.96); users who say both should remove the term. Not listed here.
        ];
        for text in untouched {
            let (out, changes) = apply_vocabulary(text, &vocab(), DEFAULT_THRESHOLD);
            assert_eq!(out, text, "changed: {changes:?}");
        }
    }

    #[test]
    fn scores() {
        assert_eq!(match_score("hold my code", "HoldMyCode"), Some(1.0));
        assert!(match_score("swift", "SwiftUI").is_none(), "length guard");
        assert!(match_score("minute", "Maynooth").unwrap_or(0.0) < DEFAULT_THRESHOLD);
        assert!(match_score("manooth", "Maynooth").unwrap() >= DEFAULT_THRESHOLD);
    }

    #[test]
    fn modes() {
        let raw = "um so i think we should uh use post gur SQL and type script, new paragraph, thanks";
        assert_eq!(
            process(raw, &opts(Mode::Exact)).text,
            "um so i think we should uh use PostgreSQL and TypeScript, new paragraph, thanks"
        );
        assert_eq!(
            process(raw, &opts(Mode::Clean)).text,
            "So I think we should use PostgreSQL and TypeScript.\n\nThanks."
        );
        let code = process("um we call the javascript api from node.js and read json", &opts(Mode::Code)).text;
        assert_eq!(code, "we call the JavaScript API from Node.js and read JSON");
        // Professional/Custom get the Clean stages here; the AI step is in the app.
        assert_eq!(process(raw, &opts(Mode::Professional)).text, process(raw, &opts(Mode::Clean)).text);
    }

    #[test]
    fn options_switch_stages_off() {
        let raw = "um hello there, new line, next";
        let mut o = TextOptions { remove_fillers: false, capitalize: false, auto_punctuation: false, spoken_line_breaks: false, ..TextOptions::default() };
        assert_eq!(process(raw, &o).text, raw);
        o.remove_fillers = true;
        assert_eq!(process(raw, &o).text, "hello there, new line, next");
    }

    /// Every stage, every mode, on text that trips byte-slicing code: accents,
    /// curly quotes, CJK, emoji, and a lone "i" behind punctuation.
    #[test]
    fn unicode_never_panics_in_any_mode() {
        let inputs = [
            "the café was nice", "je travaille à Décivra", "wir deployen in münchen", "le déploiement du système",
            "la función devuelve", "münchen", "he said “i think so”", "«i» ok", "😀i did it", "(i agree) fine",
            "日本語のテキスト new line 中文", "Ünïcödé ïs fûn, new paragraph, ok", "ß ẞ ﬁ ǅ", "i\u{301} accent", "",
        ];
        let modes = [Mode::Exact, Mode::Clean, Mode::Code, Mode::Professional, Mode::Custom];
        for mode in modes {
            for vocab in [vec![], vocab(), vec!["Café".to_string(), "Décivra".to_string(), "Zürich".to_string()]] {
                for input in inputs {
                    let o = TextOptions { mode, vocabulary: vocab.clone(), ..TextOptions::default() };
                    let _ = process(input, &o);
                }
            }
        }
        assert_eq!(capitalize_sentences("he said “i think so”"), "He said “I think so”");
        assert_eq!(capitalize_sentences("(i agree) fine"), "(I agree) fine");
        assert_eq!(capitalize_sentences("😀i did it"), "😀I did it");
        assert_eq!(capitalize_sentences("I’m here and i’ll go."), "I’m here and I’ll go.");
        // Accented terms still correct by spelling (no phonetic code for them).
        let (out, _) = apply_vocabulary("je travaille à décivra", &["Décivra".to_string()], DEFAULT_THRESHOLD);
        assert_eq!(out, "je travaille à Décivra");
    }

    #[test]
    fn short_and_symbol_terms_do_not_spread() {
        let (out, _) = apply_vocabulary("a c b c", &["C#".to_string()], DEFAULT_THRESHOLD);
        assert_eq!(out, "a c b c", "letters alone can't match C#");
        let code = process("we use rust and python with json", &TextOptions { mode: Mode::Code, ..TextOptions::default() }).text;
        assert_eq!(code, "we use rust and python with JSON");
    }

    #[test]
    fn long_dictation_with_a_big_vocabulary_is_fast() {
        let text = "we deployed the service and the team reviewed the dashboard numbers ".repeat(90); // ~1080 words
        let vocabulary: Vec<String> = (0..200).map(|i| format!("Term{i}Name")).chain(vocab()).collect();
        let started = std::time::Instant::now();
        let _ = process(&text, &TextOptions { vocabulary, ..TextOptions::default() });
        let ms = started.elapsed().as_millis();
        assert!(ms < 400, "took {ms} ms");
    }

    #[test]
    fn whisper_prompt_lists_terms() {
        assert_eq!(
            whisper_prompt(&vocab()).as_deref(),
            Some("We talked about HoldMyCode, Decivra, Maynooth, PostgreSQL, TypeScript, SwiftUI and WhisperKit.")
        );
        assert_eq!(whisper_prompt(&["Blabbit".into()]).as_deref(), Some("We talked about Blabbit."));
        assert_eq!(whisper_prompt(&[]), None);
    }
}
