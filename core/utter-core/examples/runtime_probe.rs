//! Research/bench probe: load a GGUF model once, warm it, transcribe WAVs, print timings.
//! Usage: runtime_probe [--json] <model.gguf> <a.wav>...
use std::time::Instant;
use transcribe_cpp::{Model, RunOptions};

fn load_wav(path: &str) -> Vec<f32> {
    let mut r = hound::WavReader::open(path).expect("open wav");
    let spec = r.spec();
    assert_eq!(spec.sample_rate, 16_000, "{path}: expected 16 kHz");
    assert_eq!(spec.channels, 1, "{path}: expected mono");
    r.samples::<i16>().map(|s| s.expect("sample") as f32 / 32768.0).collect()
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let json = args.first().is_some_and(|a| a == "--json");
    if json {
        args.remove(0);
    }
    let mut args = args.into_iter();
    let model_path = args.next().expect("model path");
    let t = Instant::now();
    let model = Model::load(&model_path).expect("load");
    let load_ms = t.elapsed().as_secs_f64() * 1e3;
    let mut session = model.session().expect("session");
    let t = Instant::now();
    let _ = session.run(&vec![0.0f32; 16_000], &RunOptions::default()).expect("warmup");
    let warmup_ms = t.elapsed().as_secs_f64() * 1e3;
    if json {
        println!(
            "{{\"event\":\"load\",\"model\":{:?},\"arch\":{:?},\"backend\":{:?},\"load_ms\":{load_ms:.1},\"warmup_ms\":{warmup_ms:.1}}}",
            model_path,
            model.arch(),
            model.backend()
        );
    } else {
        println!("model={} arch={} backend={} load_ms={:.0}", model_path, model.arch(), model.backend(), load_ms);
        println!("warmup_ms={warmup_ms:.0}");
    }
    for wav in args {
        let pcm = load_wav(&wav);
        let t = Instant::now();
        let r = session.run(&pcm, &RunOptions::default()).expect("run");
        let ms = t.elapsed().as_secs_f64() * 1e3;
        let audio_s = pcm.len() as f64 / 16_000.0;
        if json {
            println!(
                "{{\"event\":\"transcribe\",\"file\":{wav:?},\"audio_s\":{audio_s:.3},\"infer_ms\":{ms:.1},\"rtf\":{:.4},\"text\":{:?}}}",
                ms / 1e3 / audio_s,
                r.text.trim()
            );
        } else {
            println!("{wav}\taudio_s={audio_s:.2}\tinfer_ms={ms:.0}\trtf={:.3}\t{}", ms / 1e3 / audio_s, r.text.trim());
        }
    }
}
