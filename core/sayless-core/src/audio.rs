//! WAV loading for the CLI, bench and tests. The app captures audio natively
//! (AVAudioEngine) and hands the core 16 kHz mono f32 directly.
use crate::error::{Result, SayLessError};
use std::path::Path;

pub const SAMPLE_RATE: u32 = 16_000;

/// Reads a 16 kHz WAV (any channel count, int or float) as mono f32 in [-1, 1].
pub fn load_wav_16k_mono(path: &Path) -> Result<Vec<f32>> {
    let err = |d: String| SayLessError::AudioRead { detail: format!("{}: {d}", path.display()) };
    let mut reader = hound::WavReader::open(path).map_err(|e| err(e.to_string()))?;
    let spec = reader.spec();
    if spec.sample_rate != SAMPLE_RATE {
        return Err(err(format!("sample rate {} Hz, expected 16000 Hz", spec.sample_rate)));
    }
    let interleaved: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader
            .samples::<f32>()
            .collect::<std::result::Result<_, _>>()
            .map_err(|e| err(e.to_string()))?,
        hound::SampleFormat::Int => {
            let scale = (1i64 << (spec.bits_per_sample - 1)) as f32;
            reader
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / scale))
                .collect::<std::result::Result<_, _>>()
                .map_err(|e| err(e.to_string()))?
        }
    };
    Ok(downmix(&interleaved, spec.channels as usize))
}

/// Averages interleaved channels into mono.
pub fn downmix(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    interleaved
        .chunks_exact(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

/// Recordings shorter than this are treated as accidental taps.
pub const MIN_SPEECH_MS: u64 = 300;
/// Below this RMS (≈ -54 dBFS) over the whole clip there is no speech.
pub const SILENCE_RMS: f32 = 0.002;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipReason {
    TooShort,
    Silent,
    /// Sound, but no voice in it (background chatter, typing, a fan).
    NoSpeech,
}

/// Decides whether a recording is worth sending to the model. Silence is
/// judged on the loudest 100 ms window so a short word in a long pause still counts.
pub fn skip_reason(pcm: &[f32]) -> Option<SkipReason> {
    if (pcm.len() as u64) * 1000 / (SAMPLE_RATE as u64) < MIN_SPEECH_MS {
        return Some(SkipReason::TooShort);
    }
    let window = SAMPLE_RATE as usize / 10;
    let loudest = pcm.chunks(window).map(rms).fold(0.0f32, f32::max);
    if loudest < SILENCE_RMS {
        return Some(SkipReason::Silent);
    }
    None
}

/// Root-mean-square level of a buffer.
pub fn rms(pcm: &[f32]) -> f32 {
    if pcm.is_empty() {
        return 0.0;
    }
    (pcm.iter().map(|s| s * s).sum::<f32>() / pcm.len() as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downmix_averages_channels() {
        assert_eq!(downmix(&[1.0, 0.0, 0.5, 0.5], 2), vec![0.5, 0.5]);
        assert_eq!(downmix(&[0.25, -0.25], 1), vec![0.25, -0.25]);
    }

    #[test]
    fn skips_short_and_silent_recordings() {
        assert_eq!(skip_reason(&vec![0.3; 4_000]), Some(SkipReason::TooShort));
        assert_eq!(skip_reason(&vec![0.0005; 32_000]), Some(SkipReason::Silent));
        let mut speech = vec![0.0f32; 32_000];
        for (i, s) in speech[8_000..10_000].iter_mut().enumerate() {
            *s = 0.2 * (i as f32 * 0.1).sin();
        }
        assert_eq!(skip_reason(&speech), None);
    }

    #[test]
    fn rms_of_silence_and_square_wave() {
        assert_eq!(rms(&[]), 0.0);
        assert_eq!(rms(&[0.0; 100]), 0.0);
        assert!((rms(&[0.5, -0.5, 0.5, -0.5]) - 0.5).abs() < 1e-6);
    }

    #[test]
    fn loads_int16_stereo_and_rejects_wrong_rate() {
        let dir = std::env::temp_dir().join(format!("sayless-audio-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let ok = dir.join("stereo.wav");
        let spec = hound::WavSpec { channels: 2, sample_rate: 16_000, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
        let mut w = hound::WavWriter::create(&ok, spec).unwrap();
        for _ in 0..10 {
            w.write_sample(16384i16).unwrap();
            w.write_sample(0i16).unwrap();
        }
        w.finalize().unwrap();
        let pcm = load_wav_16k_mono(&ok).unwrap();
        assert_eq!(pcm.len(), 10);
        assert!((pcm[0] - 0.25).abs() < 1e-4);

        let bad = dir.join("44k.wav");
        let spec = hound::WavSpec { sample_rate: 44_100, ..spec };
        hound::WavWriter::create(&bad, spec).unwrap().finalize().unwrap();
        assert!(matches!(load_wav_16k_mono(&bad), Err(SayLessError::AudioRead { .. })));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
