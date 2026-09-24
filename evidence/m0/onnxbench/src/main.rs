// M0 comparison: Parakeet TDT 0.6B V3 int8 ONNX via transcribe-rs (Handy's legacy path).
use std::path::PathBuf;
use std::time::Instant;
use transcribe_rs::onnx::parakeet::{ParakeetModel, ParakeetParams};
use transcribe_rs::onnx::Quantization;

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().expect("model dir"));
    #[cfg(feature = "coreml")]
    transcribe_rs::accel::set_ort_accelerator(transcribe_rs::accel::OrtAccelerator::CoreMl);
    let ep = if cfg!(feature = "coreml") { "coreml" } else { "cpu" };
    let t = Instant::now();
    let mut model = ParakeetModel::load(&dir, &Quantization::Int8).expect("load");
    println!("engine=onnx(ort,{ep}) load_ms={:.0}", t.elapsed().as_secs_f64() * 1e3);
    let t = Instant::now();
    let _ = model.transcribe_with(&vec![0.0f32; 16_000], &ParakeetParams::default());
    println!("warmup_ms={:.0}", t.elapsed().as_secs_f64() * 1e3);
    for wav in args {
        let r = hound::WavReader::open(&wav).expect("wav");
        let pcm: Vec<f32> = r.into_samples::<i16>().map(|s| s.expect("s") as f32 / 32768.0).collect();
        let mut best = f64::MAX;
        let mut text = String::new();
        for _ in 0..3 {
            let t = Instant::now();
            let res = model.transcribe_with(&pcm, &ParakeetParams::default()).expect("run");
            best = best.min(t.elapsed().as_secs_f64() * 1e3);
            text = res.text;
        }
        let audio_s = pcm.len() as f64 / 16_000.0;
        println!("{wav}\taudio_s={audio_s:.2}\tinfer_ms_best_of_3={best:.0}\trtf={:.3}\t{}", best / 1e3 / audio_s, text.trim());
    }
}
