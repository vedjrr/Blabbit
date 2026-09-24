//! Real-model tests. They need the models fetched by `make models`
//! (or `UTTER_MODELS_DIR` pointing at a directory with the same layout).
use std::path::{Path, PathBuf};
use utter_core::{audio, wer, Engine, TranscribeOptions};

fn models_dir() -> PathBuf {
    std::env::var_os("UTTER_MODELS_DIR").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(std::env::var_os("HOME").expect("HOME")).join("Library/Application Support/Utter/Models")
    })
}

fn require_model(rel: &str) -> PathBuf {
    let p = models_dir().join(rel);
    assert!(p.is_file(), "missing test model {} — run `make models`", p.display());
    p
}

fn fixtures() -> Vec<(PathBuf, String)> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/audio");
    let mut out: Vec<_> = std::fs::read_dir(&dir)
        .expect("fixtures/audio")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "wav"))
        .filter_map(|p| std::fs::read_to_string(p.with_extension("txt")).ok().map(|r| (p, r)))
        .collect();
    out.sort();
    assert!(out.len() >= 5, "expected ≥ 5 fixture clips with references in {}", dir.display());
    out
}

const PARAKEET_V3: &str = "parakeet-tdt-0.6b-v3/parakeet-tdt-0.6b-v3-Q8_0.gguf";

#[test]
fn parakeet_v3_transcribes_fixtures_with_one_load() {
    let engine = Engine::new();
    engine.load_gguf(&require_model(PARAKEET_V3)).expect("load");
    let (mut errors, mut words) = (0, 0);
    for (wav, reference) in fixtures() {
        let pcm = audio::load_wav_16k_mono(&wav).unwrap();
        let t = engine.transcribe(&pcm, &TranscribeOptions::default()).unwrap();
        let c = wer::wer_counts(&reference, &t.text);
        eprintln!("{} wer={:.3} {:?}", wav.display(), c.wer(), t.text);
        assert!(t.skipped.is_none());
        assert!(!t.text.is_empty(), "{}: empty transcript", wav.display());
        errors += c.errors();
        words += c.reference_words;
    }
    let aggregate = errors as f64 / words as f64;
    eprintln!("aggregate wer={aggregate:.3}");
    // Measured 0.258 on the TTS set (misses are custom vocabulary words that
    // the M5 vocabulary stage targets). Guard against regressions.
    assert!(aggregate <= 0.30, "aggregate WER {aggregate:.3} regressed");
    assert_eq!(engine.load_count(), 1, "model must load exactly once");
}

#[test]
fn five_minute_recording_is_not_truncated() {
    let engine = Engine::new();
    engine.load_gguf(&require_model(PARAKEET_V3)).expect("load");
    // 5 min of real speech: fixtures separated by 1 s pauses, repeated.
    let clips: Vec<(Vec<f32>, String)> =
        fixtures().into_iter().map(|(w, r)| (audio::load_wav_16k_mono(&w).unwrap(), r)).collect();
    let target = 5 * 60 * audio::SAMPLE_RATE as usize;
    let mut pcm = Vec::with_capacity(target + 200_000);
    let mut reference = String::new();
    'fill: loop {
        for (clip, text) in &clips {
            if pcm.len() + clip.len() > target {
                break 'fill;
            }
            pcm.extend_from_slice(clip);
            pcm.extend(std::iter::repeat_n(0.0f32, audio::SAMPLE_RATE as usize));
            reference.push_str(text.trim());
            reference.push(' ');
        }
    }
    pcm.resize(target, 0.0);
    let t = engine.transcribe(&pcm, &TranscribeOptions::default()).expect("5 min transcribe");
    let ref_words = wer::normalize(&reference).len();
    let hyp_words = wer::normalize(&t.text).len();
    let w = wer::wer(&reference, &t.text);
    eprintln!("5-min: audio_ms={} infer_ms={:.0} ref_words={ref_words} hyp_words={hyp_words} wer={w:.3}", t.audio_ms, t.inference_ms);
    assert_eq!(t.audio_ms, 300_000);
    // Truncation would drop whole trailing sentences; require ≥ 90 % of the words.
    assert!(hyp_words * 10 >= ref_words * 9, "possible truncation: {hyp_words}/{ref_words} words");
    assert!(w <= 0.35, "5-min WER {w:.3}");
    // The last fixture sentence placed must appear near the end of the transcript.
    let last_ref: Vec<String> = wer::normalize(&reference).into_iter().rev().take(4).collect();
    let tail: Vec<String> = wer::normalize(&t.text).into_iter().rev().take(12).collect();
    assert!(last_ref.iter().filter(|w| tail.contains(w)).count() >= 2, "tail missing: {tail:?} vs {last_ref:?}");
}
