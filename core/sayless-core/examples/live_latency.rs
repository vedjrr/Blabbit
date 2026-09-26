//! Experiment: typing-as-you-speak cut rules vs delay and accuracy.
//!   live_latency model.gguf feed_ms trailing_ms force_after_ms gap_ms rec.wav...
//! Prints, per file: phrases, median/max lag (audio needed past the cut +
//! inference), longest wait between typed phrases, and the WER of the joined
//! phrases against one pass over the whole recording.
use sayless_core::model::{GgufModel, SpeechModel, TranscribeOptions};
use sayless_core::segment::{find_pause, find_pause_or_trailing};
use sayless_core::vad::contains_speech;

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let n = |i: usize| a[i].parse::<usize>().unwrap() * 16; // ms → samples
    let (feed, trailing, force_after, gap) = (n(1), n(2), n(3), n(4));
    let mut model = GgufModel::new(&a[0]);
    model.load().unwrap();
    let opts = TranscribeOptions::default();
    let (mut all_lag, mut all_wait, mut wers) = (Vec::new(), Vec::new(), Vec::new());
    for path in &a[5..] {
        let pcm = sayless_core::audio::load_wav_16k_mono(path.as_ref()).unwrap();
        let reference = model.transcribe(&pcm, &opts).unwrap().text;
        let (mut start, mut held, mut fed, mut last_typed) = (0usize, 0usize, 0usize, 0usize);
        let mut parts = Vec::new();
        while fed < pcm.len() {
            fed = (fed + feed).min(pcm.len());
            let p = &pcm[start..fed];
            let min_seg = 12_800.max(held - start + 12_800);
            let mut cut = find_pause_or_trailing(p, 0, min_seg, 5_600, trailing);
            if cut.is_none() && force_after > 0 && p.len() >= force_after {
                cut = find_pause(p, 0, min_seg, gap);
            }
            let Some(cut) = cut else { continue };
            let seg = &pcm[start..start + cut];
            if !contains_speech(seg) { held = start + cut; continue; }
            let t = std::time::Instant::now();
            let text = model.transcribe(seg, &opts).unwrap().text;
            let infer = t.elapsed().as_millis() as usize * 16;
            let lag = fed - (start + cut) + infer;
            all_lag.push(lag / 16);
            all_wait.push((fed + infer - last_typed) / 16);
            last_typed = fed + infer;
            parts.push(text);
            start += cut;
            held = start;
        }
        if start < pcm.len() && contains_speech(&pcm[start..]) {
            parts.push(model.transcribe(&pcm[start..], &opts).unwrap().text);
        }
        let joined = parts.join(" ");
        let c = sayless_core::wer::wer_counts(&reference, &joined);
        wers.push((c.errors(), c.reference_words));
    }
    let med = |v: &mut Vec<usize>| { v.sort(); v[v.len() / 2] };
    let max = |v: &Vec<usize>| *v.iter().max().unwrap_or(&0);
    println!("feed={} trailing={} force={} gap={}: phrases={} lag p50={}ms max={}ms  wait p50={}ms max={}ms  WER vs one-pass={:.3}",
        a[1], a[2], a[3], a[4], all_lag.len(), med(&mut all_lag.clone()), max(&all_lag), med(&mut all_wait.clone()), max(&all_wait),
        wers.iter().map(|w| w.0).sum::<usize>() as f64 / wers.iter().map(|w| w.1).sum::<usize>().max(1) as f64);
}
