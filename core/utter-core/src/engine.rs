//! The resident transcription engine: one model, loaded once, reused for every
//! dictation until the user switches models.
use crate::audio::skip_reason;
use crate::error::{Result, UtterError};
use crate::model::{GgufModel, LoadStats, MemoryRequirements, ModelMetadata, SpeechModel, TranscribeOptions, Transcription};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, RwLock};

/// `model` is locked for the whole of a load or an inference (seconds). Status
/// queries (`is_loaded`, `metadata`, `memory_requirements`, `load_count`) never
/// touch that lock, so UI threads can call them at any time without blocking.
pub struct Engine {
    model: Mutex<Option<Box<dyn SpeechModel>>>,
    loaded: AtomicBool,
    info: RwLock<Option<(ModelMetadata, MemoryRequirements)>>,
    loads: AtomicU64,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    pub fn new() -> Self {
        // Route transcribe.cpp's per-run diagnostics through the `log` facade
        // instead of stderr; they are debug-level noise for users.
        static LOGGING: std::sync::Once = std::sync::Once::new();
        LOGGING.call_once(transcribe_cpp::init_logging);
        Engine { model: Mutex::new(None), loaded: AtomicBool::new(false), info: RwLock::new(None), loads: AtomicU64::new(0) }
    }

    fn set_info(&self, info: Option<(ModelMetadata, MemoryRequirements)>) {
        *self.info.write().unwrap_or_else(|p| p.into_inner()) = info;
    }

    fn guard(&self) -> std::sync::MutexGuard<'_, Option<Box<dyn SpeechModel>>> {
        // A panic while holding the lock leaves the model in an unknown state;
        // recover the guard and let the next load replace it.
        self.model.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Loads (and warms) a GGUF model, unloading any previous one first so two
    /// models are never resident at once.
    pub fn load_gguf(&self, path: &Path) -> Result<LoadStats> {
        self.loaded.store(false, Ordering::Release);
        self.set_info(None);
        let mut slot = self.guard();
        if let Some(old) = slot.as_mut() {
            old.unload();
        }
        *slot = None;
        let mut model: Box<dyn SpeechModel> = Box::new(GgufModel::new(path));
        let stats = model.load()?;
        if let Some(meta) = model.metadata() {
            self.set_info(Some((meta, model.memory_requirements())));
        }
        *slot = Some(model);
        self.loads.fetch_add(1, Ordering::Relaxed);
        self.loaded.store(true, Ordering::Release);
        Ok(stats)
    }

    pub fn unload(&self) {
        self.loaded.store(false, Ordering::Release);
        self.set_info(None);
        let mut slot = self.guard();
        if let Some(model) = slot.as_mut() {
            model.unload();
        }
        *slot = None;
    }

    /// Lock-free; safe to call from a UI thread while a load/inference runs.
    pub fn is_loaded(&self) -> bool {
        self.loaded.load(Ordering::Acquire)
    }

    /// Number of successful model loads in this process (evidence for "loads once").
    pub fn load_count(&self) -> u64 {
        self.loads.load(Ordering::Relaxed)
    }

    pub fn metadata(&self) -> Option<ModelMetadata> {
        self.info.read().unwrap_or_else(|p| p.into_inner()).as_ref().map(|(m, _)| m.clone())
    }

    pub fn memory_requirements(&self) -> Option<MemoryRequirements> {
        self.info.read().unwrap_or_else(|p| p.into_inner()).as_ref().map(|(_, r)| *r)
    }

    pub fn transcribe(&self, pcm_16k_mono: &[f32], options: &TranscribeOptions) -> Result<Transcription> {
        if let Some(reason) = skip_reason(pcm_16k_mono) {
            return Ok(Transcription {
                text: String::new(),
                skipped: Some(reason),
                language: None,
                audio_ms: (pcm_16k_mono.len() as u64 * 1000) / crate::audio::SAMPLE_RATE as u64,
                inference_ms: 0.0,
            });
        }
        let mut slot = self.guard();
        let model = slot.as_mut().ok_or(UtterError::ModelNotLoaded)?;
        model.transcribe(pcm_16k_mono, options)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transcribe_without_model_is_a_clear_error() {
        let engine = Engine::new();
        let speech: Vec<f32> = (0..16_000).map(|i| 0.2 * (i as f32 * 0.05).sin()).collect();
        assert_eq!(engine.transcribe(&speech, &TranscribeOptions::default()), Err(UtterError::ModelNotLoaded));
    }

    #[test]
    fn short_and_silent_audio_is_skipped_without_a_model() {
        let engine = Engine::new();
        let r = engine.transcribe(&[0.0; 1_000], &TranscribeOptions::default()).unwrap();
        assert_eq!(r.skipped, Some(crate::audio::SkipReason::TooShort));
        assert!(r.text.is_empty());
    }

    #[test]
    fn missing_model_file_maps_to_model_missing() {
        let engine = Engine::new();
        let err = engine.load_gguf(Path::new("/nonexistent/model.gguf")).unwrap_err();
        assert!(matches!(err, UtterError::ModelMissing { .. }));
        assert!(!engine.is_loaded());
        assert_eq!(engine.load_count(), 0);
    }

    #[test]
    fn garbage_file_maps_to_model_corrupt() {
        let path = std::env::temp_dir().join(format!("utter-corrupt-{}.gguf", std::process::id()));
        std::fs::write(&path, b"GGUF but not really a model").unwrap();
        let err = Engine::new().load_gguf(&path).unwrap_err();
        std::fs::remove_file(&path).unwrap();
        assert!(matches!(err, UtterError::ModelCorrupt { .. }), "{err:?}");
    }
}
