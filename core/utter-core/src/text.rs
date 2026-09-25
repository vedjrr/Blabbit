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

    if (clean_like || code) && options.remove_fillers {
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
                if FILLERS.contains(&bare(word).as_str()) {
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

/// Short words said twice in a row ("I I think", "the the") lose the repeat.
pub fn remove_stutters(text: &str) -> String {
    const KEEP: &[&str] = &["no", "so", "bye", "ha", "ho", "go", "oh"];
    let mut out: Vec<&str> = Vec::new();
    for word in text.split(' ') {
        if let Some(prev) = out.last() {
            let (a, b) = (bare(prev), bare(word));
            let prev_open = !prev.ends_with(|c: char| matches!(c, ',' | '.' | '!' | '?' | ';' | ':'));
            if prev_open && !a.is_empty() && a == b && a.len() <= 3 && !KEEP.contains(&a.as_str()) {
                // Keep the second copy's punctuation: "the the." → "the."
                out.pop();
            }
        }
        out.push(word);
    }
    out.join(" ")
}

/// "new paragraph" → blank line, "new line" → line break (spoken commands).
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
        if let Some(brk) = command {
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
        if bare(core) == "i" || core.starts_with("i'") {
            w.replace_range(0..1, "I");
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
pub const CODE_TERMS: &[&str] = &[
    "JavaScript", "TypeScript", "PostgreSQL", "MySQL", "SQLite", "GitHub", "GitLab", "JSON", "YAML", "HTTP", "HTTPS",
    "API", "iOS", "macOS", "Xcode", "SwiftUI", "UIKit", "AppKit", "Kubernetes", "Docker", "Node.js", "npm", "OAuth",
    "GraphQL", "WebSocket", "localhost", "README", "CLI", "SDK", "URL", "CSS", "HTML", "Rust", "Python",
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

/// How well a spoken phrase matches a vocabulary term (0…1), or None if it
/// shouldn't be considered at all.
pub fn match_score(phrase: &str, term: &str) -> Option<f64> {
    match_details(phrase, term).map(|(score, _)| score)
}

/// Score plus whether the phrase sounds like the term (Double Metaphone).
fn match_details(phrase: &str, term: &str) -> Option<(f64, bool)> {
    let (p, t) = (letters(phrase), letters(term));
    if p.len() < 4 || t.len() < 4 {
        return (p == t && !p.is_empty()).then_some((1.0, true));
    }
    if p == t {
        return Some((1.0, true));
    }
    // Different lengths mean different words ("swift" vs "SwiftUI", "type" vs "TypeScript").
    let ratio = p.len() as f64 / t.len() as f64;
    if !(0.75..=1.34).contains(&ratio) {
        return None;
    }
    let similarity = jaro_winkler(&p, &t);
    let metaphone = DoubleMetaphone::new(None);
    let sounds_alike = metaphone.encode(&p) == metaphone.encode(&t)
        || metaphone.encode_alternate(&p) == metaphone.encode_alternate(&t);
    // Sounding alike earns a lower bar ("Manuth" ~ "Maynooth").
    Some((if sounds_alike { similarity + 0.08 } else { similarity }, sounds_alike))
}

/// A single lower-case word is probably an ordinary dictionary word
/// ("swiftly"); mixed case or digits ("postGirSQL", "utter1") are not.
fn looks_like_plain_word(word: &str) -> bool {
    let core = word.trim_matches(|c: char| !c.is_alphanumeric());
    let mut chars = core.chars();
    let first_ok = chars.next().is_some_and(|c| c.is_alphabetic());
    first_ok && chars.all(|c| c.is_lowercase())
}

/// Replaces 1–3 word phrases that match a vocabulary term, best matches first,
/// never across sentence punctuation. Returns the text and the changes made.
pub fn apply_vocabulary(text: &str, vocabulary: &[String], threshold: f64) -> (String, Vec<String>) {
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
                    if span[..len - 1].iter().any(|w| w.ends_with(|c: char| matches!(c, ',' | '.' | '!' | '?' | ';' | ':'))) {
                        break;
                    }
                    let phrase = span.join(" ");
                    let bares: Vec<String> = span.iter().map(|w| bare(w)).collect();
                    // A word already spelled as a term stays itself ("the TypeScript").
                    if len > 1 && bares.iter().any(|b| vocabulary.iter().any(|t| letters(t) == *b)) {
                        continue;
                    }
                    let has_function_word = len > 1 && bares.iter().any(|b| FUNCTION_WORDS.contains(&b.as_str()));
                    let needed = if has_function_word { threshold.max(FUNCTION_WORD_THRESHOLD) } else { threshold };
                    for term in vocabulary {
                        if let Some((score, sounds_alike)) = match_details(&phrase, term) {
                            // A real-looking single word must also sound like the term.
                            if len == 1 && score < 1.0 && looks_like_plain_word(span[0]) && !sounds_alike {
                                continue;
                            }
                            // Already written exactly as the term: nothing to do.
                            let as_written = span.iter().map(|w| w.trim_matches(|c: char| !c.is_alphanumeric())).collect::<Vec<_>>().join(" ");
                            if score >= needed && as_written != *term {
                                candidates.push((score + len as f64 * 0.001, start, len, term.as_str()));
                            }
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

/// Whisper's initial prompt: a short list of the user's terms biases decoding
/// towards their spelling (measured in M1: Whisper Small WER 0.161 → 0.032).
pub fn whisper_prompt(vocabulary: &[String]) -> Option<String> {
    let terms: Vec<&str> = vocabulary.iter().map(|s| s.trim()).filter(|s| !s.is_empty()).take(40).collect();
    (!terms.is_empty()).then(|| terms.join(", "))
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
    fn fillers_and_stutters() {
        assert_eq!(remove_fillers("So, um, I think uh we should"), "So, I think we should");
        assert_eq!(remove_fillers("Um, we should go"), "we should go");
        assert_eq!(remove_fillers("that is the end, um."), "that is the end.");
        assert_eq!(remove_fillers("Umbrella and hummus"), "Umbrella and hummus");
        assert_eq!(remove_stutters("I I think the the plan works"), "I think the plan works");
        assert_eq!(remove_stutters("no no no, that that works"), "no no no, that that works");
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
        assert_eq!(spoken_line_breaks("first point new line second point"), "first point\nsecond point");
        assert_eq!(spoken_line_breaks("intro, new paragraph, body"), "intro\n\nbody");
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
        let raw = "um so i think we should uh use post gur SQL and type script new paragraph thanks";
        assert_eq!(
            process(raw, &opts(Mode::Exact)).text,
            "um so i think we should uh use PostgreSQL and TypeScript new paragraph thanks"
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
        let raw = "um hello there new line next";
        let mut o = TextOptions { remove_fillers: false, capitalize: false, auto_punctuation: false, spoken_line_breaks: false, ..TextOptions::default() };
        assert_eq!(process(raw, &o).text, raw);
        o.remove_fillers = true;
        assert_eq!(process(raw, &o).text, "hello there new line next");
    }

    #[test]
    fn whisper_prompt_lists_terms() {
        assert_eq!(whisper_prompt(&vocab()).as_deref(), Some("HoldMyCode, Decivra, Maynooth, PostgreSQL, TypeScript, SwiftUI, WhisperKit"));
        assert_eq!(whisper_prompt(&[]), None);
    }
}
