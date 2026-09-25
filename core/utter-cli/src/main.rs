//! utter-cli — transcribe WAV files with the same engine the app uses.
//!
//!   utter-cli --model model.gguf a.wav b.wav        # text + timings (+ WER if a.txt exists)
//!   utter-cli --model model.gguf --json fixtures/audio/*.wav
use clap::Parser;
use std::path::PathBuf;
use std::process::ExitCode;
use utter_core::{audio, wer, Engine, TranscribeOptions};

#[derive(Parser)]
#[command(version, about = "Transcribe 16 kHz WAV files locally with Utter's engine")]
struct Args {
    /// Path to a GGUF speech model.
    #[arg(long)]
    model: PathBuf,
    /// Language hint (ISO code); default auto.
    #[arg(long)]
    language: Option<String>,
    /// Whisper initial prompt (vocabulary hint).
    #[arg(long)]
    prompt: Option<String>,
    /// Emit one JSON object per line instead of text.
    #[arg(long)]
    json: bool,
    /// Transcribe each file this many times (latency percentiles).
    #[arg(long, default_value_t = 1)]
    repeat: usize,
    /// After transcribing, switch to this model and report memory before/after
    /// the old model is unloaded (G3: switching frees memory).
    #[arg(long)]
    switch_to: Option<PathBuf>,
    /// Text pipeline mode applied after transcription: exact, clean, code (G4).
    #[arg(long)]
    mode: Option<String>,
    /// Personal vocabulary, comma-separated (fuzzy post-correction; also the
    /// Whisper initial prompt unless --prompt is given or UTTER_NO_VOCAB_PROMPT is set).
    #[arg(long)]
    vocab: Option<String>,
    /// Remove long silences before inference (the app's default, PARITY A16).
    #[arg(long)]
    trim: bool,
    /// WAV files (16 kHz). A sibling .txt is used as the WER reference.
    #[arg(required = true)]
    files: Vec<PathBuf>,
}

fn main() -> ExitCode {
    let args = Args::parse();
    let engine = Engine::new();
    let stats = match engine.load_gguf(&args.model) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: {e} ({})", e.detail());
            return ExitCode::FAILURE;
        }
    };
    let meta = engine.metadata();
    let arch = meta.as_ref().map(|m| m.architecture.clone()).unwrap_or_default();
    let backend = meta.as_ref().map(|m| m.backend.clone()).unwrap_or_default();
    let mem = engine.memory_requirements().unwrap_or_default();
    if args.json {
        println!(
            "{}",
            serde_json::json!({
                "event": "load", "model": args.model, "arch": arch, "backend": backend,
                "load_ms": stats.load_ms, "warmup_ms": stats.warmup_ms,
                "file_bytes": mem.file_bytes, "footprint_delta_bytes": mem.measured_load_bytes,
                "footprint_after_bytes": stats.after.footprint_bytes,
            })
        );
    } else {
        println!(
            "model {} arch={arch} backend={backend} load={:.0}ms warmup={:.0}ms footprint+{}MB",
            args.model.display(),
            stats.load_ms,
            stats.warmup_ms,
            mem.measured_load_bytes / (1024 * 1024)
        );
    }

    let vocabulary: Vec<String> =
        args.vocab.as_deref().map(|v| v.split(',').map(|t| t.trim().to_string()).filter(|t| !t.is_empty()).collect()).unwrap_or_default();
    let text_options = args.mode.as_deref().map(|m| utter_core::text::TextOptions {
        mode: match m {
            "exact" => utter_core::text::Mode::Exact,
            "code" => utter_core::text::Mode::Code,
            _ => utter_core::text::Mode::Clean,
        },
        vocabulary: vocabulary.clone(),
        ..Default::default()
    });
    let vocab_prompt = if std::env::var_os("UTTER_NO_VOCAB_PROMPT").is_some() { None } else { utter_core::text::whisper_prompt(&vocabulary) };
    let prompt = args.prompt.clone().or(vocab_prompt);
    let options = TranscribeOptions { language: args.language.clone(), translate: false, initial_prompt: prompt, trim_silence: args.trim };
    let mut processed_errors = 0usize;
    let mut failed = false;
    let mut total_errors = 0usize;
    let mut total_ref_words = 0usize;
    for file in &args.files {
        let pcm = match audio::load_wav_16k_mono(file) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("error: {e} ({})", e.detail());
                failed = true;
                continue;
            }
        };
        let mut latencies = Vec::with_capacity(args.repeat);
        let mut last = None;
        for _ in 0..args.repeat.max(1) {
            match engine.transcribe(&pcm, &options) {
                Ok(t) => {
                    latencies.push(t.inference_ms);
                    last = Some(t);
                }
                Err(e) => {
                    eprintln!("error: {}: {e} ({})", file.display(), e.detail());
                    failed = true;
                    break;
                }
            }
        }
        let Some(t) = last else { continue };
        latencies.sort_by(f64::total_cmp);
        let p50 = latencies[latencies.len() / 2];
        let reference = std::fs::read_to_string(file.with_extension("txt")).ok();
        let counts = reference.as_deref().map(|r| wer::wer_counts(r, &t.text));
        if let Some(c) = counts {
            total_errors += c.errors();
            total_ref_words += c.reference_words;
        }
        let rtf = p50 / t.audio_ms.max(1) as f64;
        let processed = text_options.as_ref().map(|o| utter_core::text::process(&t.text, o));
        if let (Some(p), Some(r)) = (&processed, reference.as_deref()) {
            processed_errors += wer::wer_counts(r, &p.text).errors();
        }
        if args.json {
            println!(
                "{}",
                serde_json::json!({
                    "event": "transcribe", "file": file, "audio_ms": t.audio_ms,
                    "infer_ms_p50": p50, "infer_ms_min": latencies[0], "infer_ms_max": latencies[latencies.len() - 1],
                    "runs": latencies.len(), "rtf": rtf, "text": t.text, "language": t.language,
                    "skipped": t.skipped.map(|s| format!("{s:?}")),
                    "reference": reference.as_deref().map(str::trim), "wer": counts.map(|c| c.wer()),
                })
            );
        } else {
            let wer_s = counts.map(|c| format!(" wer={:.3}", c.wer())).unwrap_or_default();
            println!("{}\taudio={}ms infer_p50={p50:.0}ms rtf={rtf:.3}{wer_s}\t{}", file.display(), t.audio_ms, t.text);
            if let Some(p) = &processed {
                let pw = reference.as_deref().map(|r| format!(" wer={:.3}", wer::wer_counts(r, &p.text).wer())).unwrap_or_default();
                println!("  processed{pw}\t{}\t{:?}", p.text.replace('\n', " / "), p.changes);
            }
        }
    }
    if total_ref_words > 0 {
        let agg = total_errors as f64 / total_ref_words as f64;
        if args.json {
            println!("{}", serde_json::json!({"event": "summary", "wer": agg, "errors": total_errors, "reference_words": total_ref_words, "model_loads": engine.load_count()}));
        } else {
            println!("aggregate wer={agg:.3} ({total_errors}/{total_ref_words} words) model_loads={}", engine.load_count());
            if text_options.is_some() {
                println!(
                    "aggregate processed wer={:.3} ({processed_errors}/{total_ref_words} words)",
                    processed_errors as f64 / total_ref_words as f64
                );
            }
        }
    }
    if let Some(next) = &args.switch_to {
        use utter_core::memory::process_memory;
        let mb = |b: u64| b as f64 / 1_048_576.0;
        let with_first = process_memory();
        engine.unload();
        let after_unload = process_memory();
        match engine.load_gguf(next) {
            Ok(_) => {
                let with_second = process_memory();
                println!(
                    "switch rss_mb: with_first={:.0} after_unload={:.0} with_second={:.0} | footprint_mb: with_first={:.0} after_unload={:.0} (freed {:.0}) with_second={:.0} loaded={} load_count={}",
                    mb(with_first.resident_bytes),
                    mb(after_unload.resident_bytes),
                    mb(with_second.resident_bytes),
                    mb(with_first.footprint_bytes),
                    mb(after_unload.footprint_bytes),
                    mb(with_first.footprint_bytes.saturating_sub(after_unload.footprint_bytes)),
                    mb(with_second.footprint_bytes),
                    engine.metadata().map(|m| m.architecture).unwrap_or_default(),
                    engine.load_count()
                );
            }
            Err(e) => {
                eprintln!("error: {e} ({})", e.detail());
                failed = true;
            }
        }
    }
    if failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
