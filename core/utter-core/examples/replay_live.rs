//! Replays a recording through type-as-you-speak segmenting (the parameters
//! of IncrementalTranscriber.Policy.live) and prints each phrase's text
//! without and with the speech gate.
//!   cargo run --release -p utter-core --example replay_live -- model.gguf rec.wav
use utter_core::audio::skip_reason;
use utter_core::model::{GgufModel, SpeechModel, TranscribeOptions};
use utter_core::segment::find_pause_or_trailing;
use utter_core::vad::{contains_speech, trim_silence};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let pcm = utter_core::audio::load_wav_16k_mono(args[1].as_ref()).expect("wav");
    let mut model = GgufModel::new(&args[0]);
    model.load().expect("model");
    let opts = TranscribeOptions::default();
    let mut text = |seg: &[f32]| {
        if skip_reason(seg).is_some() {
            return String::new();
        }
        let trimmed = trim_silence(seg);
        model.transcribe(trimmed.as_ref().map_or(seg, |t| &t.pcm), &opts).expect("transcribe").text
    };
    let (mut start, mut fed, mut held, mut plain) = (0, 0, 0, 0);
    let mut pieces = Vec::new();
    loop {
        let last = fed == pcm.len();
        let cut = if last {
            Some(pcm.len() - start)
        } else {
            fed = (fed + 1_600).min(pcm.len()); // 100 ms appends
            find_pause_or_trailing(&pcm[start..fed], 0, 12_800, 5_600, 8_000).map(|c| c as usize)
        };
        if let Some(cut) = cut {
            let seg = &pcm[held..start + cut];
            let t = std::time::Instant::now();
            let speech = contains_speech(seg);
            let vad_ms = t.elapsed().as_secs_f64() * 1000.0;
            let before = text(&pcm[plain..start + cut]);
            // With the gate, a phrase without speech is held and joins the next one.
            let after = if speech { text(&pcm[held..start + cut]) } else { String::new() };
            println!("{:>5.2}–{:>5.2}s speech={speech:<5} vad={vad_ms:>4.1}ms  {before:?}{}", start as f32 / 16e3, (start + cut) as f32 / 16e3,
                     if speech && held < start { format!("  held from {:.2}s → {after:?}", held as f32 / 16e3) } else { String::new() });
            pieces.push((before, after));
            start += cut;
            plain = start;
            if speech { held = start; }
        }
        if last {
            break;
        }
    }
    let join = |f: fn(&(String, String)) -> &String| pieces.iter().map(f).filter(|s| !s.trim().is_empty()).cloned().collect::<Vec<_>>().join(" ");
    println!("\nwithout gate: {}\nwith gate:    {}", join(|p| &p.0), join(|p| &p.1));
}
