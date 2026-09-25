//! Pause detection for incremental transcription of long dictations: while
//! the user is still speaking, audio up to a natural pause can be transcribed,
//! so on release only the tail is left. Splitting inside a silence keeps words
//! whole, so accuracy matches one-shot transcription (tested with real models).

/// 20 ms analysis frames at 16 kHz.
pub const FRAME: usize = 320;

fn rms(frame: &[f32]) -> f32 {
    (frame.iter().map(|s| s * s).sum::<f32>() / frame.len().max(1) as f32).sqrt()
}

/// Where to cut `pcm` (a sample index) after `from`: the middle of the last
/// silence of at least `min_silence` samples that starts at least
/// `min_segment` samples after `from`. None if there is no such pause yet.
///
/// "Silence" is relative to the recording: frames below 2.5× the quiet floor
/// (the 10th percentile of frame levels), and never above an absolute -40 dBFS,
/// so room noise and quiet microphones both work.
pub fn find_pause(pcm: &[f32], from: usize, min_segment: usize, min_silence: usize) -> Option<usize> {
    if from >= pcm.len() || pcm.len() - from < min_segment + min_silence {
        return None;
    }
    let levels: Vec<f32> = pcm[from..].chunks(FRAME).map(rms).collect();
    let mut sorted = levels.clone();
    sorted.sort_by(f32::total_cmp);
    let floor = sorted[sorted.len() / 10];
    let threshold = (floor * 2.5).clamp(0.0005, 0.01);
    let need = min_silence.div_ceil(FRAME);
    let first_allowed = min_segment / FRAME;
    // Scan backwards for the last long-enough quiet run past the minimum length.
    let mut best: Option<usize> = None;
    let mut run_end = None;
    for i in (0..levels.len()).rev() {
        if levels[i] < threshold {
            run_end.get_or_insert(i);
        } else {
            if let Some(end) = run_end.take() {
                let start = i + 1;
                // A run still going at the end is the user pausing right now:
                // only cut once speech follows it.
                let ongoing = end + 1 == levels.len();
                if !ongoing && end + 1 - start >= need && start >= first_allowed.max(1) {
                    best = Some(from + (start + end + 1) / 2 * FRAME);
                    break;
                }
            }
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    /// "Speech": a tone burst; "pause": near-silence with a little noise.
    fn signal(parts: &[(bool, f32)]) -> Vec<f32> {
        let mut out = Vec::new();
        for &(speech, seconds) in parts {
            let n = (seconds * 16_000.0) as usize;
            for i in 0..n {
                let noise = ((i * 7919 % 101) as f32 / 101.0 - 0.5) * 0.0004;
                out.push(if speech { 0.2 * (i as f32 * 0.06).sin() + noise } else { noise });
            }
        }
        out
    }

    #[test]
    fn cuts_in_the_last_pause_after_the_minimum() {
        // 4 s speech, 0.5 s pause, 4 s speech, 0.6 s pause, 3 s speech
        let pcm = signal(&[(true, 4.0), (false, 0.5), (true, 4.0), (false, 0.6), (true, 3.0)]);
        let cut = find_pause(&pcm, 0, 3 * 16_000, 8_000 * 3 / 5).expect("a pause");
        // The later pause (8.5–9.1 s) is chosen: its middle is 8.8 s.
        assert!((cut as f32 / 16_000.0 - 8.8).abs() < 0.05, "cut at {} s", cut as f32 / 16_000.0);
        // With a larger minimum only... still the 8.8 s pause.
        let cut = find_pause(&pcm, 0, 6 * 16_000, 8_000).expect("a pause");
        assert!((cut as f32 / 16_000.0 - 8.8).abs() < 0.05);
    }

    #[test]
    fn no_cut_without_a_long_enough_pause_or_after_the_start_point() {
        let pcm = signal(&[(true, 4.0), (false, 0.2), (true, 4.0)]);
        assert_eq!(find_pause(&pcm, 0, 16_000, 5_600), None, "0.2 s is a breath, not a pause");
        let pcm = signal(&[(true, 2.0), (false, 1.0), (true, 2.0)]);
        assert_eq!(find_pause(&pcm, 0, 4 * 16_000, 5_600), None, "pause comes before the minimum");
        // Search starts after `from`: the only pause is before it.
        assert_eq!(find_pause(&pcm, 3 * 16_000 + 8_000, 8_000, 5_600), None);
    }

    #[test]
    fn trailing_silence_is_not_a_cut() {
        // The user is pausing right now: don't cut until they speak again.
        let pcm = signal(&[(true, 5.0), (false, 1.0)]);
        assert_eq!(find_pause(&pcm, 0, 16_000, 5_600), None);
    }

    #[test]
    fn works_with_a_quiet_microphone_and_background_noise() {
        let mut pcm = signal(&[(true, 4.0), (false, 0.6), (true, 3.0)]);
        for s in &mut pcm {
            *s *= 0.1; // quiet mic: speech at ~0.02
        }
        let cut = find_pause(&pcm, 0, 2 * 16_000, 5_600).expect("pause found at low level");
        assert!((cut as f32 / 16_000.0 - 4.3).abs() < 0.05);
    }
}
