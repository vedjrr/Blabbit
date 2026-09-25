//! The `SpeechModel` abstraction and its transcribe.cpp (GGUF) implementation.
use crate::error::{Result, UtterError};
use crate::memory::{process_memory, ProcessMemory};
use std::path::{Path, PathBuf};
use std::time::Instant;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct TranscribeOptions {
    /// ISO language hint; `None` = auto-detect (when the model supports it).
    pub language: Option<String>,
    /// Translate to English instead of transcribing (Whisper-family only).
    pub translate: bool,
    /// Vocabulary/context prompt (Whisper-family only; ignored elsewhere).
    pub initial_prompt: Option<String>,
    /// Remove long silences first (`vad::trim_silence`).
    pub trim_silence: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Transcription {
    pub text: String,
    /// Set when the audio was not sent to the model (too short / silent).
    pub skipped: Option<crate::audio::SkipReason>,
    pub language: Option<String>,
    pub audio_ms: u64,
    pub inference_ms: f64,
    /// Silence removed before inference (ms).
    pub trimmed_ms: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ModelMetadata {
    pub path: PathBuf,
    pub architecture: String,
    pub variant: String,
    pub backend: String,
    pub languages: Vec<String>,
    pub supports_language_detect: bool,
    pub supports_translate: bool,
    pub supports_streaming: bool,
    /// The family honours the abort callback (needed for live previews).
    pub supports_cancellation: bool,
    /// 0 = no practical limit.
    pub max_audio_ms: i64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MemoryRequirements {
    /// Size of the model file on disk.
    pub file_bytes: u64,
    /// Measured footprint growth when this model was loaded (0 until loaded).
    pub measured_load_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LoadStats {
    pub load_ms: f64,
    pub warmup_ms: f64,
    pub before: ProcessMemory,
    pub after: ProcessMemory,
}

/// A speech-to-text model that is loaded once and kept resident.
pub trait SpeechModel: Send {
    fn load(&mut self) -> Result<LoadStats>;
    fn unload(&mut self);
    fn is_loaded(&self) -> bool;
    fn transcribe(&mut self, pcm_16k_mono: &[f32], options: &TranscribeOptions) -> Result<Transcription>;
    fn metadata(&self) -> Option<ModelMetadata>;
    fn supported_languages(&self) -> Vec<String>;
    fn memory_requirements(&self) -> MemoryRequirements;
    /// A token that aborts the run in flight (models that support it).
    fn cancel_token(&self) -> Option<transcribe_cpp::CancelToken> {
        None
    }
}

struct Loaded {
    session: transcribe_cpp::Session,
    metadata: ModelMetadata,
    cancel: transcribe_cpp::CancelToken,
}

/// Any GGUF model transcribe.cpp understands (Parakeet, Whisper, Moonshine, SenseVoice, …).
pub struct GgufModel {
    path: PathBuf,
    loaded: Option<Loaded>,
    measured_load_bytes: u64,
}

impl GgufModel {
    pub fn new(path: impl AsRef<Path>) -> Self {
        GgufModel { path: path.as_ref().to_path_buf(), loaded: None, measured_load_bytes: 0 }
    }
}

const WARMUP_SAMPLES: usize = 16_000;

impl SpeechModel for GgufModel {
    fn load(&mut self) -> Result<LoadStats> {
        if !self.path.is_file() {
            return Err(UtterError::ModelMissing { detail: self.path.display().to_string() });
        }
        self.unload();
        let before = process_memory();
        let started = Instant::now();
        let model = transcribe_cpp::Model::load(&self.path)?;
        let caps = model.capabilities();
        let metadata = ModelMetadata {
            path: self.path.clone(),
            architecture: model.arch(),
            variant: model.variant(),
            backend: model.backend(),
            languages: caps.languages.clone(),
            supports_language_detect: caps.supports_language_detect,
            supports_translate: caps.supports_translate,
            supports_streaming: caps.supports_streaming,
            supports_cancellation: model.supports(transcribe_cpp::Feature::Cancellation),
            max_audio_ms: caps.max_audio_ms,
        };
        let mut session = model.session()?;
        let cancel = transcribe_cpp::CancelToken::new();
        session.set_cancel_token(&cancel);
        let load_ms = started.elapsed().as_secs_f64() * 1e3;

        // Warm-up: the first run pays for Metal pipeline creation and buffer
        // allocation; doing it now keeps the first real dictation fast.
        let started = Instant::now();
        session.run(&[0.0f32; WARMUP_SAMPLES], &transcribe_cpp::RunOptions::default())?;
        let warmup_ms = started.elapsed().as_secs_f64() * 1e3;

        let after = process_memory();
        self.measured_load_bytes = after.footprint_bytes.saturating_sub(before.footprint_bytes);
        self.loaded = Some(Loaded { session, metadata, cancel });
        log::info!(
            "model loaded path={} load_ms={load_ms:.0} warmup_ms={warmup_ms:.0} footprint_delta_mb={}",
            self.path.display(),
            self.measured_load_bytes / (1024 * 1024)
        );
        Ok(LoadStats { load_ms, warmup_ms, before, after })
    }

    fn unload(&mut self) {
        if self.loaded.take().is_some() {
            log::info!("model unloaded path={}", self.path.display());
        }
    }

    fn is_loaded(&self) -> bool {
        self.loaded.is_some()
    }

    fn transcribe(&mut self, pcm: &[f32], options: &TranscribeOptions) -> Result<Transcription> {
        let loaded = self.loaded.as_mut().ok_or(UtterError::ModelNotLoaded)?;
        let is_whisper = loaded.metadata.architecture == "whisper";
        let mut run = transcribe_cpp::RunOptions {
            language: options.language.clone(),
            ..Default::default()
        };
        if options.translate && loaded.metadata.supports_translate {
            run.task = transcribe_cpp::Task::Translate;
            run.target_language = Some("en".into());
        }
        if is_whisper {
            if let Some(prompt) = options.initial_prompt.as_ref().filter(|p| !p.trim().is_empty()) {
                run.family = Some(transcribe_cpp::RunExtension::Whisper(transcribe_cpp::WhisperRunOptions {
                    initial_prompt: Some(prompt.clone()),
                    ..Default::default()
                }));
            }
        }
        let started = Instant::now();
        let result = loaded.session.run(pcm, &run)?;
        Ok(Transcription {
            text: result.text.trim().to_string(),
            skipped: None,
            language: result.language,
            audio_ms: (pcm.len() as u64 * 1000) / crate::audio::SAMPLE_RATE as u64,
            inference_ms: started.elapsed().as_secs_f64() * 1e3,
            trimmed_ms: 0,
        })
    }

    fn metadata(&self) -> Option<ModelMetadata> {
        self.loaded.as_ref().map(|l| l.metadata.clone())
    }

    fn cancel_token(&self) -> Option<transcribe_cpp::CancelToken> {
        self.loaded.as_ref().map(|l| l.cancel.clone())
    }

    fn supported_languages(&self) -> Vec<String> {
        self.loaded.as_ref().map(|l| l.metadata.languages.clone()).unwrap_or_default()
    }

    fn memory_requirements(&self) -> MemoryRequirements {
        MemoryRequirements {
            file_bytes: std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0),
            measured_load_bytes: self.measured_load_bytes,
        }
    }
}
