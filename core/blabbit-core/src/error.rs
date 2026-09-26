use thiserror::Error;

/// Errors surfaced to the app. `Display` strings are plain English and safe to
/// show to users; technical detail stays in `detail` for logs.
#[derive(Debug, Error, Clone, PartialEq)]
pub enum BlabbitError {
    #[error("The speech model file could not be found. Download it again from the Model Manager.")]
    ModelMissing { detail: String },
    #[error("The speech model file is damaged or incomplete. Delete it and download it again.")]
    ModelCorrupt { detail: String },
    #[error("This speech model is not supported by Blabbit.")]
    ModelUnsupported { detail: String },
    #[error("There is not enough memory to load this speech model. Try a smaller model.")]
    InsufficientMemory { detail: String },
    #[error("No speech model is loaded yet.")]
    ModelNotLoaded,
    #[error("Transcription failed. Please try again.")]
    InferenceFailed { detail: String },
    #[error("The recording is longer than this model can handle.")]
    InputTooLong { detail: String },
    #[error("This speech model can't transcribe the chosen language. Choose another language or model in Settings.")]
    LanguageUnsupported { detail: String },
    #[error("The audio file could not be read.")]
    AudioRead { detail: String },
    #[error("{kind}")]
    DownloadFailed { kind: DownloadIssue, detail: String },
}

/// What went wrong with a download, so the message tells the user what to do.
#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
pub enum DownloadIssue {
    #[error("The model download failed. Check your internet connection and try again.")]
    Network,
    #[error("The download server refused the request. Try again later.")]
    Server,
    #[error("Blabbit couldn't save the model file. Check that your disk has enough free space.")]
    Disk,
}

impl BlabbitError {
    /// Technical detail for logs (never shown to users).
    pub fn detail(&self) -> String {
        match self {
            BlabbitError::ModelMissing { detail }
            | BlabbitError::ModelCorrupt { detail }
            | BlabbitError::ModelUnsupported { detail }
            | BlabbitError::InsufficientMemory { detail }
            | BlabbitError::InferenceFailed { detail }
            | BlabbitError::InputTooLong { detail }
            | BlabbitError::LanguageUnsupported { detail }
            | BlabbitError::AudioRead { detail }
            | BlabbitError::DownloadFailed { detail, .. } => detail.clone(),
            BlabbitError::ModelNotLoaded => String::new(),
        }
    }
}

impl From<transcribe_cpp::Error> for BlabbitError {
    fn from(e: transcribe_cpp::Error) -> Self {
        use transcribe_cpp::Error as E;
        let detail = e.to_string();
        match e {
            E::ModelFileNotFound(_) => BlabbitError::ModelMissing { detail },
            E::ModelLoad(_) => BlabbitError::ModelCorrupt { detail },
            E::OutOfMemory(_) => BlabbitError::InsufficientMemory { detail },
            E::InputTooLong(_) => BlabbitError::InputTooLong { detail },
            // The runtime reports a language the model lacks as "unsupported language".
            E::NotImplemented(_) | E::Unsupported(_) if detail.contains("language") => BlabbitError::LanguageUnsupported { detail },
            E::NotImplemented(_) | E::Unsupported(_) => BlabbitError::ModelUnsupported { detail },
            _ => BlabbitError::InferenceFailed { detail },
        }
    }
}

pub type Result<T> = std::result::Result<T, BlabbitError>;
