//! Real-model tests. They need the models fetched by `make models`
//! (or `SAYLESS_MODELS_DIR` pointing at a directory with the same layout).
use std::path::{Path, PathBuf};
use sayless_core::{audio, wer, Engine, TranscribeOptions};

fn models_dir() -> PathBuf {
    std::env::var_os("SAYLESS_MODELS_DIR").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(std::env::var_os("HOME").expect("HOME")).join("Library/Application Support/SayLess/Models")
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

/// Real-model tests run one at a time: they compete for the GPU and CPU, and
/// the status-query test measures wall-clock latency.
static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn serial() -> std::sync::MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

const PARAKEET_V3: &str = "parakeet-tdt-0.6b-v3/parakeet-tdt-0.6b-v3-Q8_0.gguf";

#[test]
fn parakeet_v3_transcribes_fixtures_with_one_load() {
    let _serial = serial();
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
    let _serial = serial();
    let engine = Engine::new();
    engine.load_gguf(&require_model(PARAKEET_V3)).expect("load");
    // 5 min of real speech: fixtures separated by 1 s pauses, repeated.
    let clips: Vec<(Vec<f32>, String)> =
        fixtures().into_iter().map(|(w, r)| (audio::load_wav_16k_mono(&w).unwrap(), r)).collect();
    let target = 5 * 60 * audio::SAMPLE_RATE as usize;
    let mut pcm = Vec::with_capacity(target + 200_000);
    let mut reference = String::new();
    let mut last_text = String::new();
    'fill: loop {
        for (clip, text) in &clips {
            if pcm.len() + clip.len() > target {
                break 'fill;
            }
            pcm.extend_from_slice(clip);
            pcm.extend(std::iter::repeat_n(0.0f32, audio::SAMPLE_RATE as usize));
            reference.push_str(text.trim());
            reference.push(' ');
            last_text = text.trim().to_string();
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
    // The last sentence placed must appear near the end of the transcript. Its
    // vocabulary words may be misheard, so only a few of its words must match.
    let last_ref = wer::normalize(&last_text);
    let tail: Vec<String> = wer::normalize(&t.text).into_iter().rev().take(last_ref.len() + 8).collect();
    assert!(last_ref.iter().filter(|w| tail.contains(w)).count() >= 2, "tail missing: {tail:?} vs {last_ref:?}");
}

/// Status queries must not wait on the model lock (critic BLOCKER, M1): the UI
/// calls them on the main thread while a long load or inference is running.
#[test]
fn status_queries_do_not_block_during_load_or_inference() {
    let _serial = serial();
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    let engine = Arc::new(Engine::new());
    let model = require_model(PARAKEET_V3);

    let e = engine.clone();
    let loader = std::thread::spawn(move || e.load_gguf(&model).map(|_| ()));
    // A query that waited on the model lock would take as long as the whole
    // load or inference (hundreds of ms). Scheduler preemption on a busy
    // desktop can stretch a few samples, so bound the rate of slow queries and
    // keep the worst case far below a lock wait.
    let slow_limit = Duration::from_millis(1);
    let (mut worst, mut slow, mut total) = (Duration::ZERO, 0u64, 0u64);
    let mut record = |d: Duration| {
        worst = worst.max(d);
        total += 1;
        if d > slow_limit {
            slow += 1;
        }
    };
    while !loader.is_finished() {
        let t = Instant::now();
        let _ = engine.is_loaded();
        let _ = engine.metadata();
        let _ = engine.load_count();
        record(t.elapsed());
    }
    loader.join().unwrap().expect("load");
    assert!(engine.is_loaded());

    // 60 s of speech keeps the model lock busy for a while.
    let (clip, _) = &fixtures()[1];
    let one = audio::load_wav_16k_mono(clip).unwrap();
    let pcm: Vec<f32> = one.iter().cycle().take(60 * audio::SAMPLE_RATE as usize).copied().collect();
    let e = engine.clone();
    let started = Instant::now();
    let worker = std::thread::spawn(move || e.transcribe(&pcm, &TranscribeOptions::default()).map(|_| ()));
    let mut polls = 0;
    while !worker.is_finished() {
        let t = Instant::now();
        assert!(engine.is_loaded());
        assert!(engine.metadata().is_some());
        record(t.elapsed());
        polls += 1;
    }
    let inference = started.elapsed();
    worker.join().unwrap().expect("transcribe");
    eprintln!(
        "status polls during inference={polls} total_polls={total} slow_over_1ms={slow} worst_query={worst:?} inference={inference:?}"
    );
    assert!(polls > 10, "inference finished too fast to exercise contention");
    assert!(slow * 1000 <= total, "{slow} of {total} status queries took over 1 ms");
    assert!(worst < Duration::from_millis(50), "a status query blocked for {worst:?}");
    assert!(worst * 10 < inference, "worst query {worst:?} is close to the inference time {inference:?}");
}

#[test]
fn switching_models_releases_the_old_one() {
    // The app's switch path: `load_gguf` on a loaded engine (no explicit unload).
    let _serial = serial();
    use sayless_core::memory::process_memory;
    let mb = |b: u64| b / 1_048_576;
    let engine = Engine::new();
    let before = process_memory();
    engine.load_gguf(&require_model("whisper-large-v3-turbo/whisper-large-v3-turbo-Q8_0.gguf")).expect("load turbo");
    let with_first = process_memory();
    engine.load_gguf(&require_model("moonshine-base/moonshine-base-Q8_0.gguf")).expect("switch to moonshine");
    let with_second = process_memory();
    eprintln!(
        "switch rss_mb: before={} with_turbo={} with_moonshine={} | footprint_mb: before={} with_turbo={} with_moonshine={} | load_count={}",
        mb(before.resident_bytes), mb(with_first.resident_bytes), mb(with_second.resident_bytes),
        mb(before.footprint_bytes), mb(with_first.footprint_bytes), mb(with_second.footprint_bytes),
        engine.load_count()
    );
    assert_eq!(engine.metadata().map(|m| m.architecture).as_deref(), Some("moonshine"));
    // Turbo is ~1 GB resident; Moonshine ~0.2 GB. Both measures must fall by at least 500 MB.
    assert!(with_second.footprint_bytes + 500 * 1_048_576 < with_first.footprint_bytes, "footprint did not drop");
    assert!(with_second.resident_bytes + 500 * 1_048_576 < with_first.resident_bytes, "RSS did not drop");
}

#[test]
fn incremental_segments_match_one_shot_and_leave_little_for_release() {
    use std::time::Instant;
    use sayless_core::segment::find_pause;
    let _serial = serial();
    let engine = Engine::new();
    engine.load_gguf(&require_model(PARAKEET_V3)).expect("load");
    // ~60 s: fixtures with 0.8 s pauses, like someone dictating sentence by sentence.
    let clips: Vec<(Vec<f32>, String)> =
        fixtures().into_iter().map(|(w, r)| (audio::load_wav_16k_mono(&w).unwrap(), r)).collect();
    let (mut pcm, mut reference) = (Vec::new(), String::new());
    while pcm.len() < 60 * 16_000 {
        for (clip, text) in &clips {
            pcm.extend_from_slice(clip);
            pcm.extend(std::iter::repeat_n(0.0f32, 12_800));
            reference.push_str(text.trim());
            reference.push(' ');
        }
    }
    let opts = TranscribeOptions::default();

    let started = Instant::now();
    let one_shot = engine.transcribe(&pcm, &opts).unwrap().text;
    let one_shot_ms = started.elapsed().as_secs_f64() * 1e3;

    // As the recording grows every 2 s, transcribe up to the latest pause ≥ 10 s in.
    let (mut committed, mut texts, mut segments) = (0usize, Vec::<String>::new(), 0);
    let mut end = 0;
    while end < pcm.len() {
        end = (end + 32_000).min(pcm.len());
        if let Some(cut) = find_pause(&pcm[..end], committed, 10 * 16_000, 5_600) {
            texts.push(engine.transcribe(&pcm[committed..cut], &opts).unwrap().text);
            committed = cut;
            segments += 1;
        }
    }
    // Release: only the tail is left.
    let started = Instant::now();
    texts.push(engine.transcribe(&pcm[committed..], &opts).unwrap().text);
    let tail_ms = started.elapsed().as_secs_f64() * 1e3;
    let incremental = texts.iter().filter(|t| !t.is_empty()).cloned().collect::<Vec<_>>().join(" ");

    let (w1, w2) = (wer::wer(&reference, &one_shot), wer::wer(&reference, &incremental));
    eprintln!(
        "incremental: audio_s={:.0} segments={segments} one_shot_ms={one_shot_ms:.0} tail_ms={tail_ms:.0} tail_s={:.1} wer_one_shot={w1:.3} wer_incremental={w2:.3}",
        pcm.len() as f64 / 16_000.0,
        (pcm.len() - committed) as f64 / 16_000.0
    );
    assert!(segments >= 3, "expected several segments, got {segments}");
    assert!(w2 <= w1 + 0.02, "segmenting cost accuracy: {w2:.3} vs {w1:.3}");
    assert!(tail_ms * 3.0 < one_shot_ms, "release work {tail_ms:.0} ms vs one-shot {one_shot_ms:.0} ms");
}

/// PARITY A16: silence trimming on real speech. Each fixture is padded with
/// long quiet stretches (low room noise) before, inside and after the speech;
/// trimming must cut them, keep the words (WER no worse), and save inference time.
#[test]
fn trimming_long_silences_keeps_the_words_and_saves_time() {
    let _serial = serial();
    let engine = Engine::new();
    engine.load_gguf(&require_model(PARAKEET_V3)).expect("load");
    let quiet = |seconds: f32| -> Vec<f32> {
        let mut x: u32 = 7;
        (0..(seconds * 16_000.0) as usize)
            .map(|_| {
                x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                0.0015 * ((x >> 8) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0)
            })
            .collect()
    };
    let (mut orig_err, mut plain_err, mut trim_err, mut words) = (0, 0, 0, 0);
    let (mut plain_ms, mut trim_ms, mut removed_ms) = (0.0, 0.0, 0u64);
    for (wav, reference) in fixtures() {
        let speech = audio::load_wav_16k_mono(&wav).unwrap();
        let half = speech.len() / 2;
        // Split at a quiet point near the middle so no word is cut in two.
        // The quietest 200 ms in the middle half is a pause between words.
        let quiet_at = |a: usize| audio::rms(&speech[a..(a + 3_200).min(speech.len())]);
        let split = (speech.len() / 4..speech.len() * 3 / 4)
            .step_by(160)
            .min_by(|&a, &b| quiet_at(a).total_cmp(&quiet_at(b)))
            .map_or(half, |a| a + 1_600);
        let original = engine.transcribe(&speech, &TranscribeOptions::default()).unwrap();
        let padded = [quiet(3.0), speech[..split].to_vec(), quiet(4.0), speech[split..].to_vec(), quiet(3.0)].concat();
        let plain = engine.transcribe(&padded, &TranscribeOptions::default()).unwrap();
        let trimmed = engine.transcribe(&padded, &TranscribeOptions { trim_silence: true, ..Default::default() }).unwrap();
        let (p, t) = (wer::wer_counts(&reference, &plain.text), wer::wer_counts(&reference, &trimmed.text));
        eprintln!(
            "{} original wer={:.3} {:?} | plain wer={:.3} {:.0} ms | trimmed wer={:.3} {:.0} ms removed={} ms\n  plain:   {:?}\n  trimmed: {:?}",
            wav.file_name().unwrap().to_string_lossy(), wer::wer_counts(&reference, &original.text).wer(), original.text, p.wer(), plain.inference_ms,
            t.wer(), trimmed.inference_ms, trimmed.trimmed_ms, plain.text, trimmed.text
        );
        assert_eq!(trimmed.audio_ms, plain.audio_ms, "audio_ms reports the real recording length");
        assert!(trimmed.trimmed_ms >= 7_000, "{}: only {} ms removed of 10 s padding", wav.display(), trimmed.trimmed_ms);
        orig_err += wer::wer_counts(&reference, &original.text).errors();
        plain_err += p.errors();
        trim_err += t.errors();
        words += p.reference_words;
        plain_ms += plain.inference_ms;
        trim_ms += trimmed.inference_ms;
        removed_ms += trimmed.trimmed_ms;
    }
    eprintln!(
        "aggregate original wer={:.3} | padded wer={:.3} inference={plain_ms:.0} ms | trimmed wer={:.3} inference={trim_ms:.0} ms removed={removed_ms} ms",
        orig_err as f64 / words as f64,
        plain_err as f64 / words as f64,
        trim_err as f64 / words as f64
    );
    // A trimmed recording is close to the unpadded clip; the model's spelling
    // of vocabulary words ("123"/"one two three", "backend"/"back end") varies
    // a word or two either way between runs of different lengths.
    assert!(trim_err <= orig_err + 2, "trimming lost words: {trim_err} errors vs {orig_err} on the original clips");
    assert!(trim_ms < plain_ms * 0.7, "trimming should save inference time: {trim_ms:.0} vs {plain_ms:.0} ms");
}

/// PARITY A18: live previews use the resident model but stay out of the way
/// of real transcriptions: none starts while one is pending, and one already
/// running delays the real transcription by at most its own (short) run.
#[test]
fn previews_stay_out_of_the_way_of_real_transcriptions() {
    let _serial = serial();
    let engine = std::sync::Arc::new(Engine::new());
    engine.load_gguf(&require_model(PARAKEET_V3)).expect("load");
    let meta = engine.metadata().expect("metadata");
    eprintln!("{} reports supports_cancellation={}", meta.architecture, meta.supports_cancellation);
    let clips: Vec<Vec<f32>> = fixtures().iter().map(|(wav, _)| audio::load_wav_16k_mono(wav).unwrap()).collect();
    let all: Vec<f32> = clips.iter().flatten().copied().collect();
    let window: Vec<f32> = all[..8 * 16_000].to_vec(); // the app's preview cap for Parakeet
    let long: Vec<f32> = clips.iter().cycle().take(clips.len() * 12).flatten().copied().collect(); // ~6 min
    let short = clips[1].clone();
    let opts = TranscribeOptions::default();

    let t = std::time::Instant::now();
    let alone = engine.preview(&window, &opts).expect("preview").expect("a preview when idle");
    let preview_ms = t.elapsed().as_secs_f64() * 1e3;
    let t = std::time::Instant::now();
    engine.transcribe(&short, &opts).expect("short");
    let short_ms = t.elapsed().as_secs_f64() * 1e3;
    eprintln!("8 s preview alone {preview_ms:.0} ms {:?}; short transcription alone {short_ms:.0} ms", alone.text);
    assert!(!alone.text.is_empty());

    // 1. While a real transcription runs, a preview returns at once with nothing.
    let background = std::sync::Arc::clone(&engine);
    let long_for_thread = long.clone();
    let real = std::thread::spawn(move || background.transcribe(&long_for_thread, &TranscribeOptions::default()));
    std::thread::sleep(std::time::Duration::from_millis(200));
    let t = std::time::Instant::now();
    let during = engine.preview(&window, &opts);
    let refused_ms = t.elapsed().as_secs_f64() * 1e3;
    assert_eq!(during, Ok(None));
    assert!(refused_ms < 5.0, "a refused preview must not wait: {refused_ms:.2} ms");
    assert!(real.join().unwrap().is_ok_and(|t| !t.text.is_empty()));

    // 2. A real transcription arriving during a preview waits at most for that preview.
    let mut worst_extra: f64 = 0.0;
    for _ in 0..5 {
        let background = std::sync::Arc::clone(&engine);
        let w = window.clone();
        let preview = std::thread::spawn(move || background.preview(&w, &TranscribeOptions::default()));
        std::thread::sleep(std::time::Duration::from_millis(20));
        let t = std::time::Instant::now();
        let r = engine.transcribe(&short, &opts).expect("real");
        let real_ms = t.elapsed().as_secs_f64() * 1e3;
        let _ = preview.join().unwrap();
        assert!(!r.text.is_empty());
        worst_extra = worst_extra.max(real_ms - short_ms);
    }
    eprintln!("real transcription during a preview: worst extra wait {worst_extra:.0} ms (preview alone {preview_ms:.0} ms)");
    assert!(worst_extra <= preview_ms + 60.0, "waited {worst_extra:.0} ms for a {preview_ms:.0} ms preview");
    assert_eq!(engine.load_count(), 1);
}

/// PARITY C11: the same model on the CPU (Accelerate) instead of Metal, for real.
#[test]
fn cpu_accelerator_transcribes_like_metal() {
    let _serial = serial();
    let path = require_model(PARAKEET_V3);
    let (wav, _) = &fixtures()[0];
    let clip = audio::load_wav_16k_mono(wav).unwrap();
    let mut out = Vec::new();
    for accel in [sayless_core::Accelerator::Gpu, sayless_core::Accelerator::Cpu] {
        let engine = Engine::new();
        let stats = engine.load_gguf_with(&path, accel).unwrap();
        let started = std::time::Instant::now();
        let t = engine.transcribe(&clip, &TranscribeOptions::default()).unwrap();
        let ms = started.elapsed().as_secs_f64() * 1e3;
        let backend = engine.metadata().map(|m| m.backend).unwrap_or_default();
        println!("accelerator={accel:?} backend={backend} load_ms={:.0} infer_ms={ms:.0}", stats.load_ms);
        out.push((backend, t.text));
    }
    assert_ne!(out[0].0, out[1].0, "CPU must not run on the same backend as Metal");
    let differ = wer::wer(&out[0].1, &out[1].1);
    assert!(differ < 0.15, "CPU and Metal disagree: WER {differ}");
}
