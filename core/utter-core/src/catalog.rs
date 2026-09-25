//! The bundled model catalog and on-disk model store (ADR-007).
//! Only models that passed the fixture test are listed (evidence/m3).
use crate::download::{self, DownloadSpec};
use crate::error::{Result, UtterError};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Measured {
    pub wer_tts_fixtures: f64,
    pub rtf: f64,
    pub p50_ms_5s_clip: u64,
    pub footprint_mb: u64,
    pub machine: String,
    pub evidence: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct CatalogModel {
    pub id: String,
    pub name: String,
    pub family: String,
    pub description: String,
    pub languages: Vec<String>,
    pub file_name: String,
    pub size_bytes: u64,
    pub sha256: String,
    pub url: String,
    pub license: String,
    pub license_url: String,
    pub license_requires_acceptance: bool,
    pub recommended: bool,
    pub measured: Measured,
    /// A smaller quantisation of another catalog model (PARITY C6).
    #[serde(default)]
    pub variant_of: Option<String>,
}

impl CatalogModel {
    /// The quantisation, read from the file name ("…-Q4_K_M.gguf" → "Q4_K_M").
    pub fn quant(&self) -> String {
        let stem = self.file_name.trim_end_matches(".gguf");
        stem.rsplit('-').next().unwrap_or(stem).to_string()
    }
}

#[derive(Deserialize)]
struct CatalogFile {
    models: Vec<CatalogModel>,
}

/// All catalog models, parsed once from the JSON compiled into the binary.
pub fn models() -> &'static [CatalogModel] {
    static MODELS: OnceLock<Vec<CatalogModel>> = OnceLock::new();
    MODELS.get_or_init(|| {
        // The catalog is a compile-time asset covered by tests; if it ever fails
        // to parse, say so loudly and fall back to an empty list.
        serde_json::from_str::<CatalogFile>(include_str!("../models.json")).map(|c| c.models).unwrap_or_else(|e| {
            eprintln!("utter: bundled model catalog failed to parse: {e}");
            Vec::new()
        })
    })
}

pub fn find(id: &str) -> Result<&'static CatalogModel> {
    models().iter().find(|m| m.id == id).ok_or_else(|| UtterError::ModelUnsupported { detail: format!("unknown model id {id}") })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallState {
    NotInstalled,
    /// A resumable partial download of this many bytes exists.
    Partial(u64),
    Installed,
}

impl CatalogModel {
    pub fn path(&self, models_dir: &Path) -> PathBuf {
        models_dir.join(&self.id).join(&self.file_name)
    }

    pub fn download_spec(&self, models_dir: &Path) -> DownloadSpec {
        DownloadSpec { url: self.url.clone(), dest: self.path(models_dir), size_bytes: self.size_bytes, sha256: self.sha256.clone() }
    }

    /// Cheap check (existence + size). Use `verify` for the full SHA-256 check.
    pub fn state(&self, models_dir: &Path) -> InstallState {
        let path = self.path(models_dir);
        if std::fs::metadata(&path).is_ok_and(|m| m.len() == self.size_bytes) {
            return InstallState::Installed;
        }
        match download::resumable_bytes(&self.download_spec(models_dir)) {
            0 => InstallState::NotInstalled,
            n => InstallState::Partial(n),
        }
    }

    /// Full integrity check (size + SHA-256). Takes ~1 s per GB.
    pub fn verify(&self, models_dir: &Path) -> Result<()> {
        download::verify_file(&self.path(models_dir), self.size_bytes, &self.sha256)
    }

    /// Deletes the model file, any partial download, and its folder if empty.
    pub fn delete(&self, models_dir: &Path) -> Result<()> {
        let path = self.path(models_dir);
        if path.exists() {
            std::fs::remove_file(&path).map_err(|e| UtterError::DownloadFailed { kind: crate::error::DownloadIssue::Disk, detail: format!("delete {}: {e}", path.display()) })?;
        }
        download::discard_partial(&path);
        let _ = std::fs::remove_dir(models_dir.join(&self.id));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn variants_point_at_a_catalog_model_and_are_smaller() {
        for v in models().iter().filter(|m| m.variant_of.is_some()) {
            let base = find(v.variant_of.as_deref().unwrap()).expect("variant of an unknown model");
            assert!(base.variant_of.is_none(), "{} is a variant of a variant", v.id);
            assert!(v.size_bytes < base.size_bytes, "{} isn't smaller", v.id);
            assert_eq!(v.quant(), "Q4_K_M");
            assert_eq!(v.family, base.family);
            assert_ne!(v.id, base.id);
        }
        assert_eq!(find("whisper-large-v3").unwrap().quant(), "Q5_K_M");
    }

    use super::*;

    #[test]
    fn catalog_lists_every_g3_model_with_pinned_urls() {
        let ids: Vec<&str> = models().iter().map(|m| m.id.as_str()).collect();
        for want in [
            "parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v2", "whisper-small", "whisper-medium",
            "whisper-large-v3", "whisper-large-v3-turbo", "SenseVoiceSmall", "moonshine-base",
        ] {
            assert!(ids.contains(&want), "missing {want}");
        }
        for m in models() {
            assert_eq!(m.sha256.len(), 64, "{}", m.id);
            assert!(m.url.starts_with("https://huggingface.co/") && m.url.contains("/resolve/"), "{}", m.id);
            // Pinned: the revision is a 40-hex commit, never "main".
            let rev = m.url.split("/resolve/").nth(1).and_then(|r| r.split('/').next()).unwrap_or("");
            assert!(rev.len() == 40 && rev.chars().all(|c| c.is_ascii_hexdigit()), "{} not pinned: {rev}", m.id);
            assert!(m.url.ends_with(&m.file_name));
            assert!(m.size_bytes > 10_000_000);
            assert!(!m.languages.is_empty());
        }
        assert_eq!(models().iter().filter(|m| m.recommended).count(), 1);
        assert!(find("SenseVoiceSmall").unwrap().license_requires_acceptance);
        assert!(find("nope").is_err());
    }

    #[test]
    fn install_state_and_delete() {
        let dir = std::env::temp_dir().join(format!("utter-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let m = find("moonshine-base").unwrap();
        assert_eq!(m.state(&dir), InstallState::NotInstalled);
        std::fs::create_dir_all(dir.join(&m.id)).unwrap();
        std::fs::write(m.path(&dir), vec![0u8; 10]).unwrap();
        assert_eq!(m.state(&dir), InstallState::NotInstalled, "wrong size is not installed");
        assert!(matches!(m.verify(&dir), Err(UtterError::ModelCorrupt { .. })));
        m.delete(&dir).unwrap();
        assert!(!m.path(&dir).exists());
        assert!(!dir.join(&m.id).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
