//! UniFFI surface of the Rust core. Keep it coarse-grained (ADR-003).
use std::path::Path;
use std::sync::Arc;
use utter_core::{Engine, TranscribeOptions, UtterError};

uniffi::setup_scaffolding!();

/// Errors carry a plain-English `user_message` for UI and a `detail` for logs.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("{user_message}")]
    ModelMissing { user_message: String, detail: String },
    #[error("{user_message}")]
    ModelCorrupt { user_message: String, detail: String },
    #[error("{user_message}")]
    ModelUnsupported { user_message: String, detail: String },
    #[error("{user_message}")]
    InsufficientMemory { user_message: String, detail: String },
    #[error("{user_message}")]
    ModelNotLoaded { user_message: String, detail: String },
    #[error("{user_message}")]
    InferenceFailed { user_message: String, detail: String },
    #[error("{user_message}")]
    InputTooLong { user_message: String, detail: String },
    #[error("{user_message}")]
    AudioRead { user_message: String, detail: String },
}

impl From<UtterError> for CoreError {
    fn from(e: UtterError) -> Self {
        let (user_message, detail) = (e.to_string(), e.detail());
        match e {
            UtterError::ModelMissing { .. } => CoreError::ModelMissing { user_message, detail },
            UtterError::ModelCorrupt { .. } => CoreError::ModelCorrupt { user_message, detail },
            UtterError::ModelUnsupported { .. } => CoreError::ModelUnsupported { user_message, detail },
            UtterError::InsufficientMemory { .. } => CoreError::InsufficientMemory { user_message, detail },
            UtterError::ModelNotLoaded => CoreError::ModelNotLoaded { user_message, detail },
            UtterError::InferenceFailed { .. } => CoreError::InferenceFailed { user_message, detail },
            UtterError::InputTooLong { .. } => CoreError::InputTooLong { user_message, detail },
            UtterError::AudioRead { .. } => CoreError::AudioRead { user_message, detail },
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LoadInfo {
    pub load_ms: f64,
    pub warmup_ms: f64,
    pub footprint_before_bytes: u64,
    pub footprint_after_bytes: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ModelInfo {
    pub path: String,
    pub architecture: String,
    pub backend: String,
    pub languages: Vec<String>,
    pub supports_translate: bool,
    pub file_bytes: u64,
    pub measured_load_bytes: u64,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct DictationOptions {
    pub language: Option<String>,
    pub translate: bool,
    pub initial_prompt: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SkipReason {
    TooShort,
    Silent,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptionResult {
    pub text: String,
    pub skipped: Option<SkipReason>,
    pub language: Option<String>,
    pub audio_ms: u64,
    pub inference_ms: f64,
}

#[derive(uniffi::Object)]
pub struct UtterEngine {
    inner: Engine,
}

#[uniffi::export]
impl UtterEngine {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(UtterEngine { inner: Engine::new() })
    }

    /// Loads and warms a GGUF model; blocks, so call off the main thread.
    pub fn load_model(&self, path: String) -> Result<LoadInfo, CoreError> {
        let s = self.inner.load_gguf(Path::new(&path))?;
        Ok(LoadInfo {
            load_ms: s.load_ms,
            warmup_ms: s.warmup_ms,
            footprint_before_bytes: s.before.footprint_bytes,
            footprint_after_bytes: s.after.footprint_bytes,
        })
    }

    pub fn unload(&self) {
        self.inner.unload();
    }

    pub fn is_loaded(&self) -> bool {
        self.inner.is_loaded()
    }

    pub fn load_count(&self) -> u64 {
        self.inner.load_count()
    }

    pub fn model_info(&self) -> Option<ModelInfo> {
        let meta = self.inner.metadata()?;
        let mem = self.inner.memory_requirements().unwrap_or_default();
        Some(ModelInfo {
            path: meta.path.display().to_string(),
            architecture: meta.architecture,
            backend: meta.backend,
            languages: meta.languages,
            supports_translate: meta.supports_translate,
            file_bytes: mem.file_bytes,
            measured_load_bytes: mem.measured_load_bytes,
        })
    }

    /// Transcribes 16 kHz mono f32 PCM; blocks, so call off the main thread.
    pub fn transcribe(&self, pcm: Vec<f32>, options: DictationOptions) -> Result<TranscriptionResult, CoreError> {
        let opts = TranscribeOptions {
            language: options.language,
            translate: options.translate,
            initial_prompt: options.initial_prompt,
        };
        let t = self.inner.transcribe(&pcm, &opts)?;
        Ok(TranscriptionResult {
            text: t.text,
            skipped: t.skipped.map(|s| match s {
                utter_core::audio::SkipReason::TooShort => SkipReason::TooShort,
                utter_core::audio::SkipReason::Silent => SkipReason::Silent,
            }),
            language: t.language,
            audio_ms: t.audio_ms,
            inference_ms: t.inference_ms,
        })
    }
}

#[uniffi::export]
pub fn core_version() -> String {
    utter_core::runtime_version()
}

/// Word error rate between a reference and a hypothesis (used by tests/bench).
#[uniffi::export]
pub fn word_error_rate(reference: String, hypothesis: String) -> f64 {
    utter_core::wer::wer(&reference, &hypothesis)
}

/// Current process physical footprint in bytes.
#[uniffi::export]
pub fn process_footprint_bytes() -> u64 {
    utter_core::memory::process_memory().footprint_bytes
}
