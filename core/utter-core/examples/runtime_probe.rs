//! M0 research probe: load a GGUF model once, warm it, transcribe WAVs, print timings.
//! Usage: cargo run --release --example runtime_probe -- <model.gguf> <a.wav>...
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
    let mut args = std::env::args().skip(1);
    let model_path = args.next().expect("model path");
    let t = Instant::now();
    let model = Model::load(&model_path).expect("load");
    let load_ms = t.elapsed().as_secs_f64() * 1e3;
    println!("model={} arch={} backend={} load_ms={:.0}", model_path, model.arch(), model.backend(), load_ms);
    let mut session = model.session().expect("session");
    let t = Instant::now();
    let _ = session.run(&vec![0.0f32; 16_000], &RunOptions::default()).expect("warmup");
    println!("warmup_ms={:.0}", t.elapsed().as_secs_f64() * 1e3);
    for wav in args {
        let pcm = load_wav(&wav);
        let t = Instant::now();
        let r = session.run(&pcm, &RunOptions::default()).expect("run");
        let ms = t.elapsed().as_secs_f64() * 1e3;
        let audio_s = pcm.len() as f64 / 16_000.0;
        println!("{wav}\taudio_s={audio_s:.2}\tinfer_ms={ms:.0}\trtf={:.3}\t{}", ms / 1e3 / audio_s, r.text.trim());
    }
}
