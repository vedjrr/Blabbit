//! Resumable, verified model downloads (ADR-007).
//!
//! Layout while downloading: `<file>.partial` plus `<file>.partial.json` (URL,
//! expected size and SHA-256). A restart resumes with an HTTP `Range` request if
//! the sidecar still matches. The SHA-256 is computed over the whole file before
//! it is atomically renamed into place; a mismatch deletes the partial file.
use crate::error::{Result, UtterError};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DownloadSpec {
    pub url: String,
    pub dest: PathBuf,
    pub size_bytes: u64,
    /// Lowercase hex SHA-256.
    pub sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    pub downloaded: u64,
    pub total: u64,
}

/// Why a download stopped without completing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stopped {
    /// Paused: the partial file is kept for resuming.
    Paused,
    /// Cancelled: the partial file is deleted.
    Cancelled,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Completed,
    Stopped(Stopped),
}

/// Shared control for a running download (pause/cancel from another thread).
#[derive(Debug, Default, Clone)]
pub struct Control(Arc<AtomicU8>);

impl Control {
    // 0 (the default) means "keep running".
    const PAUSE: u8 = 1;
    const CANCEL: u8 = 2;

    pub fn pause(&self) {
        self.0.store(Self::PAUSE, Ordering::SeqCst);
    }
    pub fn cancel(&self) {
        self.0.store(Self::CANCEL, Ordering::SeqCst);
    }
    fn requested(&self) -> Option<Stopped> {
        match self.0.load(Ordering::SeqCst) {
            Self::PAUSE => Some(Stopped::Paused),
            Self::CANCEL => Some(Stopped::Cancelled),
            _ => None,
        }
    }
}

fn partial_path(dest: &Path) -> PathBuf {
    let mut s = dest.as_os_str().to_owned();
    s.push(".partial");
    PathBuf::from(s)
}

fn sidecar_path(dest: &Path) -> PathBuf {
    let mut s = dest.as_os_str().to_owned();
    s.push(".partial.json");
    PathBuf::from(s)
}

fn io_err(what: &str, e: impl std::fmt::Display) -> UtterError {
    UtterError::DownloadFailed { detail: format!("{what}: {e}") }
}

/// Bytes already downloaded for `spec` (0 if no matching partial file).
pub fn resumable_bytes(spec: &DownloadSpec) -> u64 {
    let sidecar_ok = fs::read(sidecar_path(&spec.dest))
        .ok()
        .and_then(|b| serde_json::from_slice::<DownloadSpec>(&b).ok())
        .is_some_and(|s| s == *spec);
    if !sidecar_ok {
        return 0;
    }
    fs::metadata(partial_path(&spec.dest)).map(|m| m.len()).unwrap_or(0).min(spec.size_bytes)
}

/// Deletes any partial download for `dest`.
pub fn discard_partial(dest: &Path) {
    let _ = fs::remove_file(partial_path(dest));
    let _ = fs::remove_file(sidecar_path(dest));
}

/// SHA-256 of a file as lowercase hex.
pub fn sha256_file(path: &Path) -> Result<String> {
    let mut file = File::open(path).map_err(|e| io_err("open", e))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf).map_err(|e| io_err("read", e))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex(&hasher.finalize()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Checks an installed model file: size and SHA-256 must both match.
pub fn verify_file(path: &Path, size_bytes: u64, sha256: &str) -> Result<()> {
    let len = fs::metadata(path).map_err(|e| UtterError::ModelMissing { detail: format!("{}: {e}", path.display()) })?.len();
    if len != size_bytes {
        return Err(UtterError::ModelCorrupt { detail: format!("{}: size {len}, expected {size_bytes}", path.display()) });
    }
    let got = sha256_file(path)?;
    if !got.eq_ignore_ascii_case(sha256) {
        return Err(UtterError::ModelCorrupt { detail: format!("{}: sha256 {got}, expected {sha256}", path.display()) });
    }
    Ok(())
}

/// Downloads `spec`, resuming a matching partial file. Blocking; run on a worker thread.
/// `progress` is called at most ~10×/s. Honors `control` between chunks.
pub fn download(spec: &DownloadSpec, control: &Control, mut progress: impl FnMut(Progress)) -> Result<Outcome> {
    if let Some(parent) = spec.dest.parent() {
        fs::create_dir_all(parent).map_err(|e| io_err("create folder", e))?;
    }
    let partial = partial_path(&spec.dest);
    let mut offset = resumable_bytes(spec);
    if offset == 0 {
        discard_partial(&spec.dest);
        fs::write(sidecar_path(&spec.dest), serde_json::to_vec(spec).map_err(|e| io_err("sidecar", e))?)
            .map_err(|e| io_err("write sidecar", e))?;
    }

    if offset < spec.size_bytes {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_connect(Some(Duration::from_secs(15)))
            .timeout_recv_body(Some(Duration::from_secs(30)))
            .build()
            .into();
        let mut request = agent.get(&spec.url);
        if offset > 0 {
            request = request.header("Range", &format!("bytes={offset}-"));
        }
        let response = request.call().map_err(|e| io_err("request", e))?;
        let status = response.status().as_u16();
        let append = match (offset, status) {
            (0, 200) => false,
            (_, 206) => true,
            // Server ignored the range: start over.
            (_, 200) => {
                offset = 0;
                false
            }
            (_, code) => return Err(UtterError::DownloadFailed { detail: format!("HTTP {code} from {}", spec.url) }),
        };
        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .append(append)
            .truncate(!append)
            .open(&partial)
            .map_err(|e| io_err("open partial", e))?;
        let mut body = response.into_body();
        let mut reader = body.as_reader();
        let mut buf = vec![0u8; 256 * 1024];
        let mut last_report = Instant::now() - Duration::from_secs(1);
        loop {
            if let Some(stop) = control.requested() {
                drop(file);
                if stop == Stopped::Cancelled {
                    discard_partial(&spec.dest);
                }
                return Ok(Outcome::Stopped(stop));
            }
            let n = reader.read(&mut buf).map_err(|e| io_err("read", e))?;
            if n == 0 {
                break;
            }
            if offset + n as u64 > spec.size_bytes {
                discard_partial(&spec.dest);
                return Err(UtterError::DownloadFailed { detail: "server sent more data than expected".into() });
            }
            file.write_all(&buf[..n]).map_err(|e| io_err("write", e))?;
            offset += n as u64;
            if last_report.elapsed() >= Duration::from_millis(100) {
                progress(Progress { downloaded: offset, total: spec.size_bytes });
                last_report = Instant::now();
            }
        }
        file.sync_all().map_err(|e| io_err("sync", e))?;
    }
    progress(Progress { downloaded: offset, total: spec.size_bytes });
    if offset != spec.size_bytes {
        // Connection closed early: keep the partial file for a later resume.
        return Err(UtterError::DownloadFailed {
            detail: format!("connection ended at {offset} of {} bytes", spec.size_bytes),
        });
    }
    let got = sha256_file(&partial)?;
    if !got.eq_ignore_ascii_case(&spec.sha256) {
        discard_partial(&spec.dest);
        return Err(UtterError::ModelCorrupt { detail: format!("downloaded file sha256 {got}, expected {}", spec.sha256) });
    }
    fs::rename(&partial, &spec.dest).map_err(|e| io_err("rename", e))?;
    let _ = fs::remove_file(sidecar_path(&spec.dest));
    Ok(Outcome::Completed)
}
