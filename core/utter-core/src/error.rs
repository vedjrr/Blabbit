use thiserror::Error;

/// Errors surfaced to the app. `Display` strings are plain English and safe to
/// show to users; technical detail stays in `detail` for logs.
#[derive(Debug, Error, Clone, PartialEq)]
pub enum UtterError {
    #[error("The speech model file could not be found. Download it again from the Model Manager.")]
    ModelMissing { detail: String },
    #[error("The speech model file is damaged or incomplete. Delete it and download it again.")]
    ModelCorrupt { detail: String },
    #[error("This speech model is not supported by Utter.")]
    ModelUnsupported { detail: String },
    #[error("There is not enough memory to load this speech model. Try a smaller model.")]
    InsufficientMemory { detail: String },
    #[error("No speech model is loaded yet.")]
    ModelNotLoaded,
    #[error("Transcription failed. Please try again.")]
    InferenceFailed { detail: String },
    #[error("The recording is longer than this model can handle.")]
    InputTooLong { detail: String },
    #[error("The audio file could not be read.")]
    AudioRead { detail: String },
}

impl UtterError {
    /// Technical detail for logs (never shown to users).
    pub fn detail(&self) -> String {
        match self {
            UtterError::ModelMissing { detail }
            | UtterError::ModelCorrupt { detail }
            | UtterError::ModelUnsupported { detail }
            | UtterError::InsufficientMemory { detail }
            | UtterError::InferenceFailed { detail }
            | UtterError::InputTooLong { detail }
            | UtterError::AudioRead { detail } => detail.clone(),
            UtterError::ModelNotLoaded => String::new(),
        }
    }
}

impl From<transcribe_cpp::Error> for UtterError {
    fn from(e: transcribe_cpp::Error) -> Self {
        use transcribe_cpp::Error as E;
        let detail = e.to_string();
        match e {
            E::ModelFileNotFound(_) => UtterError::ModelMissing { detail },
            E::ModelLoad(_) => UtterError::ModelCorrupt { detail },
            E::OutOfMemory(_) => UtterError::InsufficientMemory { detail },
            E::InputTooLong(_) => UtterError::InputTooLong { detail },
            E::NotImplemented(_) | E::Unsupported(_) => UtterError::ModelUnsupported { detail },
            _ => UtterError::InferenceFailed { detail },
        }
    }
}

pub type Result<T> = std::result::Result<T, UtterError>;
