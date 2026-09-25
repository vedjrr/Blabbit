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
    LanguageUnsupported { user_message: String, detail: String },
    #[error("{user_message}")]
    AudioRead { user_message: String, detail: String },
    #[error("{user_message}")]
    DownloadFailed { user_message: String, detail: String },
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
            UtterError::LanguageUnsupported { .. } => CoreError::LanguageUnsupported { user_message, detail },
            UtterError::AudioRead { .. } => CoreError::AudioRead { user_message, detail },
            UtterError::DownloadFailed { .. } => CoreError::DownloadFailed { user_message, detail },
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

// MARK: Model catalog and downloads (M3)

use utter_core::catalog::{self, InstallState};
use utter_core::download::{self as dl, Control, Outcome, Stopped};

#[derive(Debug, Clone, uniffi::Record)]
pub struct ModelEntry {
    pub id: String,
    pub name: String,
    pub family: String,
    pub description: String,
    pub languages: Vec<String>,
    pub size_bytes: u64,
    pub license: String,
    pub license_url: String,
    pub license_requires_acceptance: bool,
    pub recommended: bool,
    /// Word error rate on the TTS fixture set, measured on the dev machine.
    pub measured_wer: f64,
    pub measured_rtf: f64,
    pub measured_p50_ms: u64,
    pub measured_footprint_mb: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ModelInstallState {
    NotInstalled,
    Partial { bytes: u64 },
    Installed,
}

#[uniffi::export]
pub fn catalog_entries() -> Vec<ModelEntry> {
    catalog::models()
        .iter()
        .map(|m| ModelEntry {
            id: m.id.clone(),
            name: m.name.clone(),
            family: m.family.clone(),
            description: m.description.clone(),
            languages: m.languages.clone(),
            size_bytes: m.size_bytes,
            license: m.license.clone(),
            license_url: m.license_url.clone(),
            license_requires_acceptance: m.license_requires_acceptance,
            recommended: m.recommended,
            measured_wer: m.measured.wer_tts_fixtures,
            measured_rtf: m.measured.rtf,
            measured_p50_ms: m.measured.p50_ms_5s_clip,
            measured_footprint_mb: m.measured.footprint_mb,
        })
        .collect()
}

#[uniffi::export]
pub fn model_state(models_dir: String, id: String) -> Result<ModelInstallState, CoreError> {
    let m = catalog::find(&id)?;
    Ok(match m.state(Path::new(&models_dir)) {
        InstallState::NotInstalled => ModelInstallState::NotInstalled,
        InstallState::Partial(bytes) => ModelInstallState::Partial { bytes },
        InstallState::Installed => ModelInstallState::Installed,
    })
}

#[uniffi::export]
pub fn model_path(models_dir: String, id: String) -> Result<String, CoreError> {
    Ok(catalog::find(&id)?.path(Path::new(&models_dir)).display().to_string())
}

/// Full SHA-256 check (~1 s per GB); call off the main thread.
#[uniffi::export]
pub fn verify_model(models_dir: String, id: String) -> Result<(), CoreError> {
    Ok(catalog::find(&id)?.verify(Path::new(&models_dir))?)
}

/// Deletes a paused or interrupted download's partial file (Cancel on a paused row).
#[uniffi::export]
pub fn discard_partial_download(models_dir: String, id: String) -> Result<(), CoreError> {
    let path = catalog::find(&id)?.path(Path::new(&models_dir));
    utter_core::download::discard_partial(&path);
    Ok(())
}

#[uniffi::export]
pub fn delete_model(models_dir: String, id: String) -> Result<(), CoreError> {
    Ok(catalog::find(&id)?.delete(Path::new(&models_dir))?)
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DownloadOutcome {
    Completed,
    Paused,
    Cancelled,
    Failed { user_message: String, detail: String },
}

/// Implemented in Swift. Called from the download thread.
#[uniffi::export(with_foreign)]
pub trait DownloadListener: Send + Sync {
    fn on_progress(&self, downloaded: u64, total: u64);
    fn on_finished(&self, outcome: DownloadOutcome);
}

#[derive(uniffi::Object)]
pub struct ModelDownload {
    control: Control,
}

#[uniffi::export]
impl ModelDownload {
    /// Starts (or resumes) downloading `id` into `models_dir` on a background thread.
    /// `hub_endpoint` replaces `https://huggingface.co` (a mirror, as with the
    /// Hugging Face `HF_ENDPOINT` convention); the SHA-256 check is unchanged.
    #[uniffi::constructor]
    pub fn start(
        models_dir: String,
        id: String,
        hub_endpoint: Option<String>,
        listener: Arc<dyn DownloadListener>,
    ) -> Result<Arc<Self>, CoreError> {
        let mut spec = catalog::find(&id)?.download_spec(Path::new(&models_dir));
        if let Some(endpoint) = hub_endpoint.filter(|e| !e.is_empty()) {
            if let Some(rest) = spec.url.strip_prefix("https://huggingface.co") {
                spec.url = format!("{}{rest}", endpoint.trim_end_matches('/'));
            }
        }
        let control = Control::default();
        let worker_control = control.clone();
        std::thread::Builder::new()
            .name(format!("utter-download-{id}"))
            .spawn(move || {
                let outcome = match dl::download(&spec, &worker_control, |p| listener.on_progress(p.downloaded, p.total)) {
                    Ok(Outcome::Completed) => DownloadOutcome::Completed,
                    Ok(Outcome::Stopped(Stopped::Paused)) => DownloadOutcome::Paused,
                    Ok(Outcome::Stopped(Stopped::Cancelled)) => DownloadOutcome::Cancelled,
                    Err(e) => DownloadOutcome::Failed { user_message: e.to_string(), detail: e.detail() },
                };
                listener.on_finished(outcome);
            })
            .map_err(|e| CoreError::DownloadFailed { user_message: "The download could not be started.".into(), detail: e.to_string() })?;
        Ok(Arc::new(ModelDownload { control }))
    }

    pub fn pause(&self) {
        self.control.pause();
    }

    pub fn cancel(&self) {
        self.control.cancel();
    }
}

// MARK: Text pipeline (M5, G4)

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TextMode {
    Exact,
    Clean,
    Code,
    Professional,
    Custom,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TextSettings {
    pub mode: TextMode,
    pub vocabulary: Vec<String>,
    pub vocabulary_threshold: f64,
    pub remove_fillers: bool,
    pub capitalize: bool,
    pub auto_punctuation: bool,
    pub spoken_line_breaks: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ProcessedText {
    pub text: String,
    pub changes: Vec<String>,
}

/// Runs the pure Rust stages for `settings.mode` (fast; safe on any thread).
#[uniffi::export]
pub fn process_text(raw: String, settings: TextSettings) -> ProcessedText {
    use utter_core::text::{self, Mode, TextOptions};
    let options = TextOptions {
        mode: match settings.mode {
            TextMode::Exact => Mode::Exact,
            TextMode::Clean => Mode::Clean,
            TextMode::Code => Mode::Code,
            TextMode::Professional => Mode::Professional,
            TextMode::Custom => Mode::Custom,
        },
        vocabulary: settings.vocabulary,
        vocabulary_threshold: settings.vocabulary_threshold,
        remove_fillers: settings.remove_fillers,
        capitalize: settings.capitalize,
        auto_punctuation: settings.auto_punctuation,
        spoken_line_breaks: settings.spoken_line_breaks,
    };
    // A bug in a stage must never crash dictation (a panic would cross the FFI
    // boundary): fall back to the raw transcript and say so.
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| text::process(&raw, &options))) {
        Ok(processed) => ProcessedText { text: processed.text, changes: processed.changes },
        Err(panic) => {
            let why = panic.downcast_ref::<String>().cloned().or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()));
            log::error!("text pipeline panicked; using the raw transcript: {}", why.unwrap_or_default());
            ProcessedText { text: raw, changes: vec!["text pipeline error: raw transcript used".into()] }
        }
    }
}

/// Whisper initial prompt built from the user's vocabulary.
#[uniffi::export]
pub fn vocabulary_prompt(vocabulary: Vec<String>) -> Option<String> {
    utter_core::text::whisper_prompt(&vocabulary)
}

/// Default similarity threshold for vocabulary corrections.
#[uniffi::export]
pub fn default_vocabulary_threshold() -> f64 {
    utter_core::text::DEFAULT_THRESHOLD
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ErrorMessage {
    pub kind: String,
    pub message: String,
}

/// The user-facing text of every core error kind (for the error-mapping test and docs).
#[uniffi::export]
pub fn error_messages() -> Vec<ErrorMessage> {
    use utter_core::error::{DownloadIssue, UtterError as E};
    let d = String::new;
    let all = [
        ("ModelMissing", E::ModelMissing { detail: d() }),
        ("ModelCorrupt", E::ModelCorrupt { detail: d() }),
        ("ModelUnsupported", E::ModelUnsupported { detail: d() }),
        ("InsufficientMemory", E::InsufficientMemory { detail: d() }),
        ("ModelNotLoaded", E::ModelNotLoaded),
        ("InferenceFailed", E::InferenceFailed { detail: d() }),
        ("InputTooLong", E::InputTooLong { detail: d() }),
        ("LanguageUnsupported", E::LanguageUnsupported { detail: d() }),
        ("AudioRead", E::AudioRead { detail: d() }),
        ("DownloadFailed", E::DownloadFailed { kind: DownloadIssue::Network, detail: d() }),
        ("DownloadServer", E::DownloadFailed { kind: DownloadIssue::Server, detail: d() }),
        ("DownloadDisk", E::DownloadFailed { kind: DownloadIssue::Disk, detail: d() }),
    ];
    all.into_iter().map(|(kind, e)| ErrorMessage { kind: kind.into(), message: e.to_string() }).collect()
}

// MARK: Benchmark support (M6)

/// Reads a WAV file as 16 kHz mono samples (fixtures for utter-bench).
#[uniffi::export]
pub fn load_wav_16k_mono(path: String) -> Result<Vec<f32>, CoreError> {
    Ok(utter_core::audio::load_wav_16k_mono(Path::new(&path))?)
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct ProcessMemory {
    pub resident_bytes: u64,
    pub footprint_bytes: u64,
}

/// Current resident size and physical footprint of this process.
#[uniffi::export]
pub fn process_memory() -> ProcessMemory {
    let m = utter_core::memory::process_memory();
    ProcessMemory { resident_bytes: m.resident_bytes, footprint_bytes: m.footprint_bytes }
}
