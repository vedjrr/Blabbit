//! Energy voice-activity detection: removes long silences before inference
//! (PARITY A16). transcribe.cpp ships no VAD model, so this is a frame-energy
//! detector with an adaptive noise floor and generous hangover; it only ever
//! removes stretches that are well below the speech level around them.
//!
//! `contains_speech` is the other half: a Silero VAD check (the model Handy
//! uses) that tells a voice from background chatter, keyboard and room noise,
//! which are often as loud as a quiet speaker.
use crate::audio::{rms, SAMPLE_RATE, SILENCE_RMS};

/// 20 ms analysis frames.
const FRAME: usize = SAMPLE_RATE as usize / 50;
/// Audio kept on each side of speech (soft onsets, trailing consonants, and
/// the pause context the models were trained with).
const HANGOVER_FRAMES: usize = 25; // 500 ms
/// Speech must be this far above the noise floor (≈ +10 dB).
const FLOOR_RATIO: f32 = 3.2;
/// Less than this to remove: leave the audio untouched.
const MIN_REMOVED_FRAMES: usize = 25; // 500 ms

#[derive(Debug, Clone, PartialEq)]
pub struct Trimmed {
    pub pcm: Vec<f32>,
    /// Milliseconds of silence removed.
    pub removed_ms: u64,
}

/// Returns the audio with long silences removed, or `None` when there is
/// nothing worth removing (or no speech at all, which `skip_reason` handles).
pub fn trim_silence(pcm: &[f32]) -> Option<Trimmed> {
    let frames: Vec<f32> = pcm.chunks(FRAME).map(rms).collect();
    if frames.len() < 2 * HANGOVER_FRAMES {
        return None;
    }
    let threshold = speech_threshold(&frames);
    let speech: Vec<bool> = frames.iter().map(|&e| e >= threshold).collect();
    if !speech.iter().any(|&s| s) {
        return None;
    }
    // Keep every frame within the hangover of a speech frame.
    let mut keep = vec![false; frames.len()];
    for (i, _) in speech.iter().enumerate().filter(|(_, &s)| s) {
        let lo = i.saturating_sub(HANGOVER_FRAMES);
        let hi = (i + HANGOVER_FRAMES).min(frames.len() - 1);
        keep[lo..=hi].iter_mut().for_each(|k| *k = true);
    }
    let removed = keep.iter().filter(|&&k| !k).count();
    if removed < MIN_REMOVED_FRAMES {
        return None;
    }
    let mut out = Vec::with_capacity(pcm.len() - removed * FRAME);
    for (i, chunk) in pcm.chunks(FRAME).enumerate() {
        if keep[i] {
            out.extend_from_slice(chunk);
        }
    }
    let removed_samples = pcm.len() - out.len();
    Some(Trimmed { pcm: out, removed_ms: removed_samples as u64 * 1000 / SAMPLE_RATE as u64 })
}

/// Silero speech probability that counts as speech; Handy uses the same.
/// On the user's recordings, background chatter peaked at 0.16 and quiet
/// real speech reached 0.33+ (scored in `WINDOW`s, below).
pub const SPEECH_PROBABILITY: f32 = 0.3;
/// Speech is looked for in windows of this many samples (2 s), each scored
/// from a fresh model state, one second apart. Silero's state sticks: after
/// a stretch of chatter it scored a clear "Hi, my name is …" 0.16 instead of
/// 1.0, and after a quiet phrase it missed 10 s of soft speech (0.24 vs 0.61).
const WINDOW: usize = 2 * SAMPLE_RATE as usize;
const HOP: usize = SAMPLE_RATE as usize;

/// True when `pcm` (16 kHz mono) has a voice in it. Newest windows first and
/// stops at the first speech, so a real dictation costs a few milliseconds.
/// If the VAD can't run, says yes: a dictation is never dropped because of it.
pub fn contains_speech(pcm: &[f32]) -> bool {
    let mut vad = match silero_vad_crs::SileroVad::new() {
        Ok(vad) => vad,
        Err(e) => {
            log::warn!("speech detector unavailable, transcribing anyway: {e:?}");
            return true;
        }
    };
    let step = vad.source_window_samples();
    let starts = (0..pcm.len().saturating_sub(WINDOW - HOP).max(1)).step_by(HOP);
    for start in starts.rev() {
        vad.reset();
        let window = &pcm[start..(start + WINDOW).min(pcm.len())];
        for chunk in window.chunks(step) {
            if chunk.len() < step / 2 {
                break;
            }
            let mut padded;
            let chunk = if chunk.len() == step {
                chunk
            } else {
                // A last partial step of real audio: pad it with silence.
                padded = chunk.to_vec();
                padded.resize(step, 0.0);
                &padded
            };
            match vad.forward_chunk(chunk) {
                Ok(p) if p >= SPEECH_PROBABILITY => return true,
                Ok(_) => {}
                Err(e) => {
                    log::warn!("speech detector failed, transcribing anyway: {e:?}");
                    return true;
                }
            }
        }
    }
    false
}

/// Noise floor = the 10th-percentile frame level; speech sits well above it
/// and never below the absolute silence level.
fn speech_threshold(frames: &[f32]) -> f32 {
    let mut sorted = frames.to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let floor = sorted[sorted.len() / 10].max(1e-5);
    (floor * FLOOR_RATIO).max(SILENCE_RMS)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(seconds: f32, amp: f32) -> Vec<f32> {
        (0..(seconds * SAMPLE_RATE as f32) as usize).map(|i| amp * (i as f32 * 0.07).sin()).collect()
    }

    /// Deterministic low-level noise (a room, a fan).
    fn noise(seconds: f32, amp: f32) -> Vec<f32> {
        let mut x: u32 = 12345;
        (0..(seconds * SAMPLE_RATE as f32) as usize)
            .map(|_| {
                x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                amp * ((x >> 8) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0)
            })
            .collect()
    }

    #[test]
    fn long_pauses_are_removed_and_speech_kept_with_hangover() {
        let pcm = [noise(2.0, 0.001), tone(1.0, 0.2), noise(3.0, 0.001), tone(1.0, 0.2), noise(2.0, 0.001)].concat();
        let t = trim_silence(&pcm).expect("trimmed");
        // 2 s speech + 500 ms hangover around each of the 2 phrases (4 × 0.5 s).
        let kept_ms = t.pcm.len() as u64 * 1000 / SAMPLE_RATE as u64;
        assert!((3950..=4100).contains(&kept_ms), "kept {kept_ms} ms");
        assert_eq!(t.removed_ms + kept_ms, 9000);
        // Every loud sample survived.
        let loud_in = pcm.iter().filter(|s| s.abs() > 0.05).count();
        let loud_out = t.pcm.iter().filter(|s| s.abs() > 0.05).count();
        assert_eq!(loud_in, loud_out);
    }

    #[test]
    fn continuous_speech_is_left_alone() {
        let pcm = [tone(0.3, 0.1), noise(0.4, 0.001), tone(2.0, 0.1)].concat();
        assert_eq!(trim_silence(&pcm), None);
    }

    #[test]
    fn quiet_speech_in_a_noisy_room_is_kept() {
        // Fan noise at 0.02 RMS-ish, speech only ~4× above it.
        let pcm = [noise(2.0, 0.035), tone(1.5, 0.09), noise(2.0, 0.035)].concat();
        let t = trim_silence(&pcm).expect("trimmed");
        let loud_in = pcm.iter().filter(|s| s.abs() > 0.08).count();
        let loud_out = t.pcm.iter().filter(|s| s.abs() > 0.08).count();
        assert!(loud_out as f32 >= loud_in as f32 * 0.99, "{loud_out}/{loud_in}");
    }

    #[test]
    fn tones_noise_and_silence_are_not_speech() {
        assert!(!contains_speech(&[]));
        assert!(!contains_speech(&vec![0.0; 32_000]));
        assert!(!contains_speech(&noise(3.0, 0.02)));
        assert!(!contains_speech(&tone(2.0, 0.2)));
    }

    #[test]
    fn pure_silence_and_short_clips_are_not_touched() {
        assert_eq!(trim_silence(&noise(3.0, 0.0005)), None);
        assert_eq!(trim_silence(&tone(0.2, 0.2)), None);
        assert_eq!(trim_silence(&[]), None);
    }
}
