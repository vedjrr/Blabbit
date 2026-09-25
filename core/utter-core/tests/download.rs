//! Downloader tests against a local HTTP server that supports Range and can
//! simulate dropped connections, ignored ranges, corruption and slow links.
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use utter_core::download::{self, Control, DownloadSpec, Outcome, Stopped, Timing};
use utter_core::UtterError;

#[derive(Clone, Default)]
struct Behaviour {
    /// Close the connection after sending this many body bytes (first request only).
    drop_after: Option<usize>,
    ignore_range: bool,
    corrupt: bool,
    /// Delay per 64 KiB chunk.
    slow: Option<Duration>,
    /// Send the headers, then nothing (a stalled connection).
    hang: bool,
    status: Option<u16>,
}

struct Server {
    url: String,
    requests: Arc<AtomicUsize>,
    ranges: Arc<Mutex<Vec<Option<String>>>>,
}

fn serve(body: Vec<u8>, behaviour: Behaviour) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/model.gguf", listener.local_addr().unwrap());
    let requests = Arc::new(AtomicUsize::new(0));
    let ranges = Arc::new(Mutex::new(Vec::new()));
    let (req_count, range_log) = (requests.clone(), ranges.clone());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let n = req_count.fetch_add(1, Ordering::SeqCst);
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut range = None;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                    break;
                }
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("range: bytes=") {
                    range = Some(v.trim().trim_end_matches('-').to_string());
                }
            }
            range_log.lock().unwrap().push(range.clone());
            if let Some(code) = behaviour.status {
                let _ = write!(stream, "HTTP/1.1 {code} Nope\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                continue;
            }
            let mut data = body.clone();
            if behaviour.corrupt {
                data[0] ^= 0xff;
            }
            let start: usize = if behaviour.ignore_range { 0 } else { range.as_deref().and_then(|r| r.parse().ok()).unwrap_or(0) };
            let slice = &data[start..];
            let head = if start > 0 {
                format!("HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{}/{}\r\nConnection: close\r\n\r\n", slice.len(), data.len() - 1, data.len())
            } else {
                format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", slice.len())
            };
            let _ = stream.write_all(head.as_bytes());
            if behaviour.hang {
                std::thread::sleep(Duration::from_secs(3));
                continue;
            }
            let limit = if n == 0 { behaviour.drop_after.unwrap_or(usize::MAX) } else { usize::MAX };
            let mut sent = 0;
            for chunk in slice.chunks(64 * 1024) {
                if let Some(d) = behaviour.slow {
                    std::thread::sleep(d);
                }
                let take = chunk.len().min(limit.saturating_sub(sent));
                if stream.write_all(&chunk[..take]).is_err() {
                    break;
                }
                sent += take;
                if sent >= limit {
                    break;
                }
            }
        }
    });
    Server { url, requests, ranges }
}

fn payload(len: usize) -> (Vec<u8>, String) {
    let data: Vec<u8> = (0..len).map(|i| (i * 31 % 251) as u8).collect();
    let sha = Sha256::digest(&data).iter().map(|b| format!("{b:02x}")).collect();
    (data, sha)
}

fn sweep_old_temp_dirs() {
    let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) else { return };
    for entry in entries.flatten() {
        let old = entry.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|age| age > Duration::from_secs(600));
        if old && entry.file_name().to_string_lossy().starts_with("utter-dl-") {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

fn temp_dest(name: &str) -> PathBuf {
    // Per process, so concurrent `cargo test` runs don't share files; folders
    // left by earlier runs (over 10 minutes old) are swept here.
    sweep_old_temp_dirs();
    let dir = std::env::temp_dir().join(format!("utter-dl-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("model.gguf")
}

#[test]
fn downloads_and_verifies() {
    let (data, sha) = payload(1_000_000);
    let server = serve(data.clone(), Behaviour::default());
    let spec = DownloadSpec { url: server.url, dest: temp_dest("ok"), size_bytes: data.len() as u64, sha256: sha };
    let mut last = None;
    let outcome = download::download(&spec, &Control::default(), |p| last = Some(p)).unwrap();
    assert_eq!(outcome, Outcome::Completed);
    assert_eq!(std::fs::read(&spec.dest).unwrap(), data);
    assert_eq!(last.unwrap().downloaded, data.len() as u64);
    assert!(download::verify_file(&spec.dest, spec.size_bytes, &spec.sha256).is_ok());
    assert_eq!(download::resumable_bytes(&spec), 0, "partial files cleaned up");
}

#[test]
fn resumes_with_range_after_dropped_connection() {
    let (data, sha) = payload(2_000_000);
    let server = serve(data.clone(), Behaviour { drop_after: Some(700_000), ..Default::default() });
    let spec = DownloadSpec { url: server.url.clone(), dest: temp_dest("resume"), size_bytes: data.len() as u64, sha256: sha };
    // The connection drops after 700 kB; the downloader resumes on its own.
    assert_eq!(download::download(&spec, &Control::default(), |_| {}).unwrap(), Outcome::Completed);
    assert_eq!(std::fs::read(&spec.dest).unwrap(), data);
    let ranges = server.ranges.lock().unwrap().clone();
    assert_eq!(ranges[0], None);
    let resumed_at: u64 = ranges[1].as_deref().expect("second request used Range").parse().unwrap();
    assert!((600_000..=700_000).contains(&resumed_at), "resumed at {resumed_at}");
    assert_eq!(server.requests.load(Ordering::SeqCst), 2);
}

#[test]
fn stopped_process_keeps_partial_for_a_later_resume() {
    // A download interrupted by pause (or the app quitting) resumes with Range next time.
    let (data, sha) = payload(2_000_000);
    let server = serve(data.clone(), Behaviour { slow: Some(Duration::from_millis(20)), ..Default::default() });
    let spec = DownloadSpec { url: server.url.clone(), dest: temp_dest("later"), size_bytes: data.len() as u64, sha256: sha };
    let control = Control::default();
    let c = control.clone();
    let first = download::download(&spec, &control, move |p| {
        if p.downloaded > 600_000 {
            c.pause();
        }
    });
    assert_eq!(first.unwrap(), Outcome::Stopped(Stopped::Paused));
    let kept = download::resumable_bytes(&spec);
    assert!(kept > 600_000, "kept {kept}");
    assert_eq!(download::download(&spec, &Control::default(), |_| {}).unwrap(), Outcome::Completed);
    assert_eq!(std::fs::read(&spec.dest).unwrap(), data);
    assert_eq!(server.ranges.lock().unwrap()[1].as_deref(), Some(kept.to_string().as_str()));
}

#[test]
fn transfer_longer_than_the_body_budget_completes() {
    // ~1.2 s transfer against a 250 ms segment budget: the old total body
    // timeout failed every download that took longer than the budget.
    let (data, sha) = payload(4_000_000);
    let server = serve(data.clone(), Behaviour { slow: Some(Duration::from_millis(20)), ..Default::default() });
    let spec = DownloadSpec { url: server.url.clone(), dest: temp_dest("long"), size_bytes: data.len() as u64, sha256: sha };
    let timing = Timing { segment: Duration::from_millis(250), ..Timing::default() };
    let started = std::time::Instant::now();
    let outcome = download::download_with(&spec, &Control::default(), |_| {}, timing).unwrap();
    assert_eq!(outcome, Outcome::Completed);
    assert!(started.elapsed() > Duration::from_millis(750), "transfer too fast to exercise the budget");
    assert_eq!(std::fs::read(&spec.dest).unwrap(), data);
    let requests = server.requests.load(Ordering::SeqCst);
    assert!(requests >= 3, "expected several resumed segments, got {requests}");
    assert!(server.ranges.lock().unwrap()[1..].iter().all(Option::is_some), "every later segment used Range");
}

#[test]
fn stalled_connection_fails_and_keeps_nothing_lost() {
    let (data, sha) = payload(500_000);
    let server = serve(data, Behaviour { hang: true, ..Default::default() });
    let spec = DownloadSpec { url: server.url, dest: temp_dest("stall"), size_bytes: 500_000, sha256: sha };
    let timing = Timing { segment: Duration::from_millis(300), ..Timing::default() };
    let started = std::time::Instant::now();
    let err = download::download_with(&spec, &Control::default(), |_| {}, timing).unwrap_err();
    assert!(matches!(err, UtterError::DownloadFailed { .. }), "{err:?}");
    assert!(started.elapsed() < Duration::from_secs(2), "stall detected in {:?}", started.elapsed());
}

#[test]
fn server_ignoring_range_restarts_cleanly() {
    let (data, sha) = payload(1_500_000);
    let server = serve(data.clone(), Behaviour { drop_after: Some(400_000), ignore_range: true, ..Default::default() });
    let spec = DownloadSpec { url: server.url, dest: temp_dest("norange"), size_bytes: data.len() as u64, sha256: sha };
    let _ = download::download(&spec, &Control::default(), |_| {});
    assert_eq!(download::download(&spec, &Control::default(), |_| {}).unwrap(), Outcome::Completed);
    assert_eq!(std::fs::read(&spec.dest).unwrap(), data);
}

#[test]
fn checksum_mismatch_deletes_partial_and_reports_corrupt() {
    let (data, sha) = payload(500_000);
    let server = serve(data.clone(), Behaviour { corrupt: true, ..Default::default() });
    let spec = DownloadSpec { url: server.url, dest: temp_dest("corrupt"), size_bytes: data.len() as u64, sha256: sha };
    let err = download::download(&spec, &Control::default(), |_| {}).unwrap_err();
    assert!(matches!(err, UtterError::ModelCorrupt { .. }), "{err:?}");
    assert!(!spec.dest.exists());
    assert_eq!(download::resumable_bytes(&spec), 0);
}

#[test]
fn pause_keeps_partial_and_cancel_deletes_it() {
    let (data, sha) = payload(3_000_000);
    let server = serve(data.clone(), Behaviour { slow: Some(Duration::from_millis(5)), ..Default::default() });
    let spec = DownloadSpec { url: server.url, dest: temp_dest("pause"), size_bytes: data.len() as u64, sha256: sha };

    let control = Control::default();
    let c = control.clone();
    let paused = download::download(&spec, &control, move |p| {
        if p.downloaded > 500_000 {
            c.pause();
        }
    })
    .unwrap();
    assert_eq!(paused, Outcome::Stopped(Stopped::Paused));
    assert!(download::resumable_bytes(&spec) > 0, "pause keeps the partial file");

    let control = Control::default();
    let c = control.clone();
    let cancelled = download::download(&spec, &control, move |_| c.cancel()).unwrap();
    assert_eq!(cancelled, Outcome::Stopped(Stopped::Cancelled));
    assert_eq!(download::resumable_bytes(&spec), 0, "cancel deletes the partial file");
    assert!(!spec.dest.exists());

    // Retry after cancel downloads from scratch and verifies.
    assert_eq!(download::download(&spec, &Control::default(), |_| {}).unwrap(), Outcome::Completed);
    assert_eq!(std::fs::read(&spec.dest).unwrap(), data);
}

#[test]
fn http_errors_and_unreachable_hosts_are_plain_errors() {
    let (data, sha) = payload(1000);
    let server = serve(data, Behaviour { status: Some(404), ..Default::default() });
    let spec = DownloadSpec { url: server.url, dest: temp_dest("404"), size_bytes: 1000, sha256: sha.clone() };
    let err = download::download(&spec, &Control::default(), |_| {}).unwrap_err();
    assert!(matches!(err, UtterError::DownloadFailed { .. }));
    assert_eq!(err.to_string(), "The download server refused the request. Try again later.");

    let spec = DownloadSpec { url: "http://127.0.0.1:1/model.gguf".into(), dest: temp_dest("refused"), size_bytes: 1000, sha256: sha.clone() };
    let err = download::download(&spec, &Control::default(), |_| {}).unwrap_err();
    assert_eq!(err.to_string(), "The model download failed. Check your internet connection and try again.");

    // A destination that can't be created is a disk problem, not a network one.
    let blocker = temp_dest("disk");
    std::fs::write(&blocker, b"a file where a folder should be").unwrap();
    let spec = DownloadSpec { url: "http://127.0.0.1:1/x".into(), dest: blocker.join("sub/model.gguf"), size_bytes: 1000, sha256: sha };
    let err = download::download(&spec, &Control::default(), |_| {}).unwrap_err();
    assert_eq!(err.to_string(), "Utter couldn't save the model file. Check that your disk has enough free space.");
}

#[test]
fn verify_file_detects_truncation_and_bit_flips() {
    let (data, sha) = payload(10_000);
    let dest = temp_dest("verify");
    std::fs::write(&dest, &data).unwrap();
    assert!(download::verify_file(&dest, 10_000, &sha).is_ok());
    std::fs::write(&dest, &data[..9_000]).unwrap();
    assert!(matches!(download::verify_file(&dest, 10_000, &sha), Err(UtterError::ModelCorrupt { .. })));
    let mut flipped = data.clone();
    flipped[5] ^= 1;
    std::fs::write(&dest, &flipped).unwrap();
    assert!(matches!(download::verify_file(&dest, 10_000, &sha), Err(UtterError::ModelCorrupt { .. })));
    assert!(matches!(download::verify_file(&dest.with_extension("missing"), 1, &sha), Err(UtterError::ModelMissing { .. })));
}
