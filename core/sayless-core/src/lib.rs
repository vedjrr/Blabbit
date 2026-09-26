pub mod audio;
pub mod catalog;
pub mod download;
pub mod engine;
pub mod error;
pub mod memory;
pub mod model;
pub mod segment;
pub mod text;
pub mod vad;
pub mod wer;

pub use engine::Engine;
pub use error::{Result, SayLessError};
pub use model::{Accelerator, GgufModel, SpeechModel, TranscribeOptions, Transcription};

pub fn runtime_version() -> String {
    format!("transcribe-cpp {} ({})", transcribe_cpp::version(), transcribe_cpp::version_commit())
}

/// True when this build can run inference on the GPU via Metal.
pub fn metal_available() -> bool {
    transcribe_cpp::backend_available(transcribe_cpp::Backend::Metal)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_reports_version() {
        assert!(runtime_version().starts_with("transcribe-cpp 0.2"));
    }

    #[test]
    fn metal_backend_is_compiled_in() {
        assert!(metal_available(), "Metal backend missing from this build");
    }
}
