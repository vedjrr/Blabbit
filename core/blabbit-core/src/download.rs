//! Resumable, verified model downloads (ADR-007).
//!
//! Layout while downloading: `<file>.partial` plus `<file>.partial.json` (URL,
//! expected size and SHA-256). A restart resumes with an HTTP `Range` request if
//! the sidecar still matches. The SHA-256 is computed over the whole file before
//! it is atomically renamed into place; a mismatch deletes the partial file.
use crate::error::{DownloadIssue, Result, BlabbitError};
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

fn net_err(what: &str, e: impl std::fmt::Display) -> BlabbitError {
    BlabbitError::DownloadFailed { kind: DownloadIssue::Network, detail: format!("{what}: {e}") }
}

fn disk_err(what: &str, e: impl std::fmt::Display) -> BlabbitError {
    BlabbitError::DownloadFailed { kind: DownloadIssue::Disk, detail: format!("{what}: {e}") }
}

fn server_err(detail: String) -> BlabbitError {
    BlabbitError::DownloadFailed { kind: DownloadIssue::Server, detail }
}

/// Bytes already downloaded for `spec` (0 if no matching partial file).
pub fn resumable_bytes(spec: &DownloadSpec) -> u64 {
    let sidecar_ok = fs::read(sidecar_path(&spec.dest))
        .ok()
        .and_then(|b| serde_json::from_slice::<DownloadSpec>(&b).ok())
        // The URL may differ (a mirror): the same bytes are identified by
        // destination, size and SHA-256.
        .is_some_and(|s| s.dest == spec.dest && s.size_bytes == spec.size_bytes && s.sha256.eq_ignore_ascii_case(&spec.sha256));
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
    let mut file = File::open(path).map_err(|e| disk_err("open", e))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf).map_err(|e| disk_err("read", e))?;
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
    let len = fs::metadata(path).map_err(|e| BlabbitError::ModelMissing { detail: format!("{}: {e}", path.display()) })?.len();
    if len != size_bytes {
        return Err(BlabbitError::ModelCorrupt { detail: format!("{}: size {len}, expected {size_bytes}", path.display()) });
    }
    let got = sha256_file(path)?;
    if !got.eq_ignore_ascii_case(sha256) {
        return Err(BlabbitError::ModelCorrupt { detail: format!("{}: sha256 {got}, expected {sha256}", path.display()) });
    }
    Ok(())
}

/// Network timing for `download_with`.
#[derive(Debug, Clone, Copy)]
pub struct Timing {
    pub connect: Duration,
    /// Time allowed for the response headers.
    pub response: Duration,
    /// ureq's body timeout is a total budget, not an idle timeout, so the body is
    /// read in segments of this length. A segment that ends (budget used up, or the
    /// connection dropped) after receiving data resumes with a new Range request
    /// automatically; one that receives nothing fails (the partial file is kept).
    pub segment: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Timing { connect: Duration::from_secs(15), response: Duration::from_secs(30), segment: Duration::from_secs(30) }
    }
}

/// First byte position of a `Content-Range: bytes <start>-<end>/<total>` header.
fn content_range_start(value: &str) -> Option<u64> {
    value.trim().strip_prefix("bytes ")?.split('-').next()?.trim().parse().ok()
}

/// Downloads `spec`, resuming a matching partial file. Blocking; run on a worker thread.
/// `progress` is called at most ~10×/s. Honors `control` between chunks.
pub fn download(spec: &DownloadSpec, control: &Control, progress: impl FnMut(Progress)) -> Result<Outcome> {
    download_with(spec, control, progress, Timing::default())
}

pub fn download_with(spec: &DownloadSpec, control: &Control, mut progress: impl FnMut(Progress), timing: Timing) -> Result<Outcome> {
    if let Some(parent) = spec.dest.parent() {
        fs::create_dir_all(parent).map_err(|e| disk_err("create folder", e))?;
    }
    let partial = partial_path(&spec.dest);
    let mut offset = resumable_bytes(spec);
    if offset == 0 {
        discard_partial(&spec.dest);
        fs::write(sidecar_path(&spec.dest), serde_json::to_vec(spec).map_err(|e| disk_err("sidecar", e))?)
            .map_err(|e| disk_err("write sidecar", e))?;
    }

    // Set once a server answers a Range request with 200: resuming is then
    // impossible, so the body is read in one go with no segment budget.
    let mut ranges_ignored = false;
    while offset < spec.size_bytes {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            // Status codes are handled below (server problem, not the network).
            .http_status_as_error(false)
            .timeout_connect(Some(timing.connect))
            .timeout_recv_response(Some(timing.response))
            // Without Range support a segment can't resume, so allow one long
            // budget instead of none: a stalled connection still ends, and
            // Pause/Cancel (checked between reads) still take effect.
            .timeout_recv_body(Some(if ranges_ignored { timing.segment * 60 } else { timing.segment }))
            .build()
            .into();
        let mut request = agent.get(&spec.url);
        if offset > 0 {
            request = request.header("Range", &format!("bytes={offset}-"));
        }
        let response = request.call().map_err(|e| net_err("request", e))?;
        let status = response.status().as_u16();
        let append = match (offset, status) {
            (0, 200) => false,
            (_, 206) => {
                let start = response.headers().get("content-range").and_then(|v| v.to_str().ok()).and_then(content_range_start);
                if start != Some(offset) {
                    return Err(server_err(format!("server resumed at {start:?}, expected byte {offset}")));
                }
                true
            }
            // Server ignored the range: start over.
            (_, 200) => {
                offset = 0;
                ranges_ignored = true;
                false
            }
            (_, code) => return Err(server_err(format!("HTTP {code} from {}", spec.url))),
        };
        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .append(append)
            .truncate(!append)
            .open(&partial)
            .map_err(|e| disk_err("open partial", e))?;
        let mut body = response.into_body();
        let mut reader = body.as_reader();
        let mut buf = vec![0u8; 256 * 1024];
        let mut last_report: Option<Instant> = None;
        let segment_start = offset;
        loop {
            if let Some(stop) = control.requested() {
                drop(file);
                if stop == Stopped::Cancelled {
                    discard_partial(&spec.dest);
                }
                return Ok(Outcome::Stopped(stop));
            }
            let n = match reader.read(&mut buf) {
                Ok(n) => n,
                // The segment budget ran out, or the connection dropped, after
                // this request delivered data: resume from here. Each round must
                // make progress, so this can't loop forever.
                Err(_) if offset > segment_start => break,
                Err(e) => return Err(net_err("read", e)),
            };
            if n == 0 {
                break;
            }
            if offset + n as u64 > spec.size_bytes {
                discard_partial(&spec.dest);
                return Err(server_err("server sent more data than expected".into()));
            }
            file.write_all(&buf[..n]).map_err(|e| disk_err("write", e))?;
            offset += n as u64;
            if last_report.is_none_or(|t| t.elapsed() >= Duration::from_millis(100)) {
                progress(Progress { downloaded: offset, total: spec.size_bytes });
                last_report = Some(Instant::now());
            }
        }
        file.sync_all().map_err(|e| disk_err("sync", e))?;
        if offset == segment_start || offset >= spec.size_bytes {
            // Nothing new (the connection ended early) or done.
            break;
        }
    }
    progress(Progress { downloaded: offset, total: spec.size_bytes });
    if offset != spec.size_bytes {
        // Connection closed early: keep the partial file for a later resume.
        return Err(BlabbitError::DownloadFailed {
            kind: DownloadIssue::Network,
            detail: format!("connection ended at {offset} of {} bytes", spec.size_bytes),
        });
    }
    let got = sha256_file(&partial)?;
    if !got.eq_ignore_ascii_case(&spec.sha256) {
        discard_partial(&spec.dest);
        return Err(BlabbitError::ModelCorrupt { detail: format!("downloaded file sha256 {got}, expected {}", spec.sha256) });
    }
    fs::rename(&partial, &spec.dest).map_err(|e| disk_err("rename", e))?;
    let _ = fs::remove_file(sidecar_path(&spec.dest));
    Ok(Outcome::Completed)
}
