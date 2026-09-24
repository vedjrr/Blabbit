# Utter architecture

Reference studied: Handy `v0.9.7` + 6 commits (`8f9cf53`, 2026-09-19), cloned read-only at `/tmp/handy-ref`.
Permalink base used below: `H/` = `https://github.com/cjpais/Handy/blob/8f9cf53cd1410cda26beea39ff802ac306e39585/`.

Machine used for every measurement in this file: Apple M4, 16 GB, macOS 27.0 (26A428).
Toolchain: Swift 6.4 (Command Line Tools, **no Xcode.app installed**), rustc 1.98.1, cargo 1.98.1, cmake 4.4.3.

## 1. How Handy is built (component map)

| Concern | Handy implementation | Source |
|---|---|---|
| App shell | Tauri 2 (Rust backend + React/Vite web UI), tray icon, `tauri-nspanel` overlay on macOS | `H/src-tauri/Cargo.toml`, `H/src-tauri/src/tray.rs`, `H/src-tauri/src/overlay.rs` |
| Coordinator | `TranscriptionCoordinator` state machine (idle → recording → transcribing → processing → paste) | `H/src-tauri/src/transcription_coordinator.rs`, `H/src-tauri/src/actions.rs` |
| Audio capture | `cpal` input stream → `rubato` resampler → 16 kHz mono f32; ring buffer `rtrb`; optional always-on mic; Silero or Earshot VAD trims silence | `H/src-tauri/src/audio_toolkit/audio/recorder.rs`, `.../resampler.rs`, `H/src-tauri/src/managers/audio.rs`, `.../vad/` |
| Hotkey | Two implementations: `handy-keys` crate (CGEventTap; allows modifier-only and fn) and Tauri global-shortcut (Carbon). Default macOS binding `option+space`; `escape` = cancel; separate "transcribe with post-process" binding. Modes: push-to-talk / toggle / hold-or-toggle with `hold_threshold_ms` | `H/src-tauri/src/shortcut/handy_keys.rs`, `H/src-tauri/src/shortcut/mod.rs`, `H/src-tauri/src/settings.rs:860` |
| Secure input | Polls `IsSecureEventInputEnabled`; when stuck, shadow-registers keyed bindings via Carbon (not blocked by secure input) and warns in tray | `H/src-tauri/src/secure_input.rs` |
| Insertion | `enigo` synthetic ⌘V (or direct typing, Shift+Insert, Ctrl+Shift+V, external script, none). "Reliable paste" on macOS publishes a *pasteboard promise* and uses `provideDataForType` as a read receipt before restoring the old clipboard, guarded by `changeCount`. Optional auto-submit (Enter / Ctrl+Enter / Cmd+Enter), trailing space, paste delays | `H/src-tauri/src/clipboard.rs`, `H/src-tauri/src/paste_tx/macos.rs`, `H/src-tauri/src/input.rs` |
| Inference | `transcribe-cpp` 0.2.3 (ggml, Metal on macOS) for **all GGUF catalog models**; legacy `transcribe-rs` ONNX (CPU) engines for older Parakeet/Moonshine/SenseVoice/GigaAM/Canary/Cohere bundles | `H/src-tauri/src/managers/transcription.rs:22-37` |
| Model catalog | Bundled `catalog.json` (69 GGUF models, pinned HF revision, per-quant SHA-256 + size), files fetched from `huggingface.co/handy-computer/<model>-gguf/resolve/<sha>/…`; also scans the shared HF cache and a custom models dir | `H/src-tauri/src/catalog/catalog.json`, `H/src-tauri/src/catalog/mod.rs`, `H/src-tauri/src/managers/model.rs` |
| Downloads | Resumable HTTP range download with SHA-256 verify, cancel; hf-hub fork with cancellable downloads | `H/src-tauri/src/managers/model/download.rs` |
| Model lifecycle | Load on selection, warm, unload after configurable idle timeout (never / immediately / 2–60 min) | `H/src-tauri/src/settings.rs` (`ModelUnloadTimeout`) |
| Post-processing | Custom-word fuzzy correction (n-gram ≤ 3, Soundex + string distance, threshold), filler-word removal, output language detection, OpenCC zh conversion; optional LLM post-process (OpenAI, Z.ai, OpenRouter, Anthropic, Groq, Cerebras, Bedrock, custom OpenAI-compatible, Apple Intelligence on macOS) with prompt library | `H/src-tauri/src/audio_toolkit/text.rs:151`, `H/src-tauri/src/llm_client.rs`, `H/src-tauri/src/apple_intelligence.rs` |
| History | SQLite (`rusqlite`), stores WAV per entry, star/save, retry transcription, retention policy and limit | `H/src-tauri/src/managers/history.rs`, `H/src-tauri/src/commands/history.rs` |
| Settings | JSON store via `tauri-plugin-store`, ~60 fields | `H/src-tauri/src/settings.rs:369-516` |

## 2. Decisions (ADRs)

### ADR-001 — Build with SwiftPM + Makefile, not an .xcodeproj
- **Context.** Xcode.app is not installed on the build machine (`xcodebuild` → "requires Xcode, but active developer directory … is a command line tools instance"). CLT ships Swift 6.4, SwiftPM, Swift Testing, `codesign`, `notarytool`, `stapler` (verified with `xcrun --find`). No `metal` shader compiler, no `xcodebuild -create-xcframework`.
- **Decision.** The app is a SwiftPM package (`app/Package.swift`) with targets `UtterFFI` (C module over the UniFFI header), `UtterCore` (generated Swift bindings + Swift wrappers), `Utter` (executable), `UtterTests`. `make bundle` assembles `build/Utter.app` (Info.plist, entitlements, hardened-runtime codesign). `make test` = `cargo test` + `swift test` (Swift Testing).
- **Consequences.** Builds identically with or without Xcode. No asset catalogs: the icon is an `.icns` built with `iconutil` (in CLT). No Xcode UI tests; UI behaviour is tested through AppKit-free logic and manual checklists. If Xcode is installed later nothing changes.
- **Sources.** SwiftPM docs https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/ ; measured: `make build` → `Built …/build/Utter.app`, `codesign -dv` → `flags=0x10002(adhoc,runtime)`.

### ADR-002 — Inference runtime: `transcribe-cpp` (ggml + Metal) for every model family
- **Context.** Hypothesis from MILESTONES was whisper.cpp for Whisper + ONNX Runtime/transcribe-rs for Parakeet/SenseVoice/Moonshine. Handy itself has since moved all catalog models to GGUF via `transcribe-cpp`, keeping ONNX only for legacy bundles (Handy runs ONNX **CPU-only** on macOS, see comments in `H/src-tauri/Cargo.toml`).
- **Test.** `core/utter-core/examples/runtime_probe.rs`, log `evidence/m0/runtime_probe.log`. On M4, Metal (`backend=MTL0`), 4.3–5.1 s TTS clips:
  - Parakeet TDT 0.6B V3 Q8_0: load 261 ms (warm file cache; first-ever load 7.7 s, one-time Metal pipeline compile), warm-up 102 ms, **inference 93–129 ms, RTF 0.019–0.028**.
  - Whisper Small Q8_0: load 143 ms, **inference 406–445 ms, RTF 0.084–0.099**.
- **Decision.** One runtime, `transcribe-cpp` 0.2.3 (MIT, static link, `metal` feature), behind our own `SpeechModel` trait. Model files are the GGUF conversions at pinned revisions of `huggingface.co/handy-computer/*-gguf` (the weights keep their upstream licences, §3). Families available through it include parakeet (V2, V3, 110M, 1.1B), whisper (tiny → large-v3, turbo), moonshine, sensevoice, canary, gigaam, qwen3-asr, voxtral.
- **Rejected.** `whisper-rs` (Whisper only, second ggml copy); `ort`/`transcribe-rs` (≈ 30 MB ONNX Runtime dylib, CPU on macOS in Handy's config, and slower than ggml-Metal for Parakeet); WhisperKit/FluidAudio Core ML (Swift-only, per-family, models need ANE compilation; kept as a possible "Better" experiment for M6).
- **Consequence.** Static lib is ~141 MB unstripped (debug line tables); the release app binary gets stripped in M7. Deployment target pinned to 14.0 in `core/.cargo/config.toml` and the Makefile; `-C default-linker-libraries=yes` so Rust-linked test/CLI binaries get compiler-rt (`__isPlatformVersionAtLeast` from ggml's `@available`).
- **Sources.** https://github.com/handy-computer/transcribe.cpp (MIT), https://crates.io/crates/transcribe-cpp, `H/src-tauri/src/managers/transcription.rs`.

### ADR-003 — Swift ↔ Rust boundary: UniFFI (proc-macro), static library, coarse calls
- **Decision.** Crate `core/utter-ffi` (`staticlib`) exposes a small UniFFI surface; `core/uniffi-bindgen` generates `UtterCore.swift` + `UtterFFI.h` + modulemap in library mode (`make bindings`). Generated files are build products (git-ignored).
- **Boundary rule.** Only coarse operations cross: `Engine.load(model)`, `Engine.transcribe(pcm: [Float]) -> Transcript`, model catalog/downloads, text-processing pipeline. Audio capture, hotkeys, insertion and UI stay in Swift. PCM crosses once per utterance (5 min × 16 kHz × 4 B = 19 MB copy, ~2 ms). Long-running Rust calls run off the main thread (`Task.detached` / UniFFI async); progress comes back through UniFFI callback interfaces.
- **Rejected.** Hand-written C ABI (more unsafe glue, no generated error enums); XCFramework (needs `xcodebuild`, ADR-001).
- **Sources.** https://mozilla.github.io/uniffi-rs/latest/ ; measured: `CoreBridgeTests.rustCoreIsLinkedAndReportsRuntime` passes under `swift test`.

### ADR-004 — Audio capture: AVAudioEngine in Swift, converted to 16 kHz mono f32
- **Decision.** `AVAudioEngine.inputNode` tap at the hardware format; `AVAudioConverter` to 16 kHz mono Float32 on the tap thread; samples appended to a pre-reserved buffer under an `os_unfair_lock`. The engine is prepared at launch and started on key-down; "keep microphone warm" (Handy's always-on mic) is an opt-in setting because it keeps the orange mic indicator lit. Device selection via Core Audio `AudioObjectID` set on the input unit (`kAudioOutputUnitProperty_CurrentDevice`). Route changes: observe `AVAudioEngineConfigurationChange` + Core Audio device-alive listener; on loss mid-recording keep captured audio and finish the utterance.
- **Why not cpal/Rust.** cpal on macOS is Core Audio underneath; staying in Swift avoids a realtime callback across FFI and lets us use AVFoundation permission APIs directly.
- **Target.** key-down → first buffer < 50 ms (GOAL G1), measured in M1/M4 with `os_signpost` + log.
- **Sources.** https://developer.apple.com/documentation/avfaudio/avaudioengine , `H/src-tauri/src/audio_toolkit/audio/recorder.rs`.

### ADR-005 — Global hotkey: active CGEventTap on its own thread, Carbon fallback under secure input
- **Decision.** A `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap, keyDown|keyUp|flagsChanged)` on a dedicated thread with its own run loop. Matching events are **swallowed** (return `nil`) so the shortcut never leaks into the focused app; supports modifier-only shortcuts (e.g. Right ⌥, fn/Globe) which Carbon cannot. Tap-disabled-by-timeout events re-enable the tap. When `IsSecureEventInputEnabled()` is sustained, keyed shortcuts are shadow-registered via Carbon `RegisterEventHotKey` (the same approach as Handy's `secure_input.rs`). Push-to-talk, toggle and hold-or-toggle (tap < threshold = toggle) modes; `Esc` cancels while recording.
- **Permission.** Active taps need Accessibility (we need it anyway for AX insertion) — one prompt, not two.
- **Default shortcut.** `⌥ Space`, matching Handy's macOS default, configurable.
- **Sources.** https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:) , `H/src-tauri/src/shortcut/handy_keys.rs`, `H/src-tauri/src/secure_input.rs`.

### ADR-006 — Text insertion strategy chain with per-app table
- **Order (default).** 0) `IsSecureEventInputEnabled()` → abort, overlay notice. 1) **AX**: focused element (`AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute`), set `kAXSelectedTextAttribute`, then verify by reading back value/selected range; unverifiable = fall through. 2) **Paste**: snapshot *all* `NSPasteboardItem`s × all types, write transcript with transient/concealed markers (`org.nspasteboard.TransientType`, `ConcealedType`), post ⌘V via `CGEvent` (`.combinedSessionState` source), restore after the target reads it (promise receipt via `NSPasteboardItemDataProvider`, like Handy's reliable paste) or a timeout, and **only if `changeCount` is still ours**. 3) **Type**: `CGEvent.keyboardSetUnicodeString` in ≤ 20-UTF-16 chunks.
- **Per-app table.** Bundle-ID keyed defaults: terminals (Terminal, iTerm2, Warp, Ghostty) → paste; Electron/Chromium (VS Code, Cursor, Slack, Discord, Notion, Chrome, Arc) → paste (AX set on Chromium text areas is unreliable); native Cocoa (TextEdit, Notes, Mail, Xcode, Messages) → AX. User overrides in Settings → Text Insertion.
- **Better than Handy (to be demonstrated in M2).** Handy has no AX insertion (`grep -rn AXUIElement src-tauri/src` → no hits) and its default paste restores only plain text, or an image when no text was present (`H/src-tauri/src/clipboard.rs:63-106`); its receipt-based "reliable paste" is debug-gated (`H/src-tauri/src/clipboard.rs:806`). We restore every item and type (RTF, images, file URLs, multiple items) by default.
- **Sources.** https://developer.apple.com/documentation/applicationservices/axuielement_h , https://developer.apple.com/documentation/appkit/nspasteboard , http://nspasteboard.org/ , `H/src-tauri/src/paste_tx/macos.rs`.

### ADR-007 — Model catalog and storage layout
- **Layout.** `~/Library/Application Support/Utter/Models/<model-id>/<file>.gguf`; in-flight `<file>.gguf.partial` + `<file>.gguf.partial.json` (URL, expected size, SHA-256, ETag) for HTTP range resume; verified file renamed atomically. History DB and settings live beside it in `~/Library/Application Support/Utter/`.
- **Catalog.** Our own `models.json` bundled in the app (id, family, display name, languages, size, URL at pinned HF revision, SHA-256, licence, `verified` flag). A model only appears as "Supported" after it passes the fixture test in M3; otherwise it is listed "Unsupported: <reason>".
- **Downloads.** Implemented in Rust (`ureq` + native TLS via Security.framework, streaming SHA-256) so it is testable under `cargo test` against a local HTTP server with Range support.
- **Verified in M0.** Parakeet V3 and Whisper Small downloaded from pinned URLs; `shasum -a 256` equals the catalog hashes (`5859f779…`, `9b9c8811…`).

### ADR-008 — Threading model
- Main actor: AppKit/SwiftUI only. Never blocks.
- Hotkey thread: CGEventTap run loop; posts events to the coordinator (actor).
- Audio: AVAudioEngine render/tap thread → lock-protected append, no allocation after the first `reserveCapacity`.
- `DictationCoordinator` (Swift actor): state machine idle → recording → transcribing → processing → inserting.
- Rust engine: one `Engine` object owning the loaded model + session behind a `Mutex`; called from a detached task; model loads once at launch on a background task, warms up with 1 s of silence, stays resident until the user switches models (unload + RSS measurement in M3).
- Insertion: main thread (AX, pasteboard and CGEvent posting are main-thread-safe and fast); paste-restore wait happens off-main.

### ADR-009 — Persistence
- Settings: `UserDefaults` via a Codable `Settings` struct with explicit keys, one migration version field.
- History: SQLite via GRDB.swift 7 (MIT) in `~/Library/Application Support/Utter/history.sqlite`; FTS5 for search; audio stored only if the user enables it.
- Secrets (cloud LLM keys): Keychain (`kSecClassGenericPassword`).

### ADR-010 — Text pipeline split: pure Rust stages + optional Swift LLM providers
- `RawTranscript → [Processor] → FinalText`. Deterministic stages in Rust (`utter-core::text`): whitespace/punctuation normalisation, filler removal, vocabulary fuzzy correction (n-gram, Jaro-Winkler + Double Metaphone with threshold), code mode rules. Each is a pure function with unit tests.
- LLM stages (Professional, Custom) behind a Swift `TextProcessor` protocol: Ollama (local HTTP, `localhost:11434`) and Anthropic (cloud, off by default, key in Keychain). Network only when the user enables a provider — never in Exact/Clean/Code.

### ADR-011 — Distribution
- Hardened runtime; the only entitlement is `com.apple.security.device.audio-input` (needed for the mic under hardened runtime). Not sandboxed: CGEventTap posting and cross-app AX writes are not possible from the App Sandbox; we distribute outside the Mac App Store (same as Handy).
- `make dmg`: `codesign` with Developer ID → `hdiutil` DMG → `notarytool submit --wait` → `stapler staple`. Updates via Sparkle 2 (2.10.0, SwiftPM binary target) with EdDSA-signed appcast.

## 3. Licences

| Component | Licence | Obligation | Source |
|---|---|---|---|
| Handy (reference only) | MIT | Keep notice if any snippet is reused (none so far) | `/tmp/handy-ref/LICENSE` |
| transcribe.cpp / transcribe-cpp crate | MIT | Notice in About/credits | https://github.com/handy-computer/transcribe.cpp |
| ggml (vendored in transcribe.cpp) | MIT | Notice | https://github.com/ggml-org/ggml |
| transcribe-rs (not used) | MIT | — | https://crates.io/crates/transcribe-rs |
| whisper-rs (not used) | Unlicense | — | https://crates.io/crates/whisper-rs |
| ort / ONNX Runtime (not used) | MIT OR Apache-2.0 / MIT | — | https://crates.io/crates/ort |
| UniFFI | MPL-2.0 | Unmodified library use; file-level copyleft only on modified UniFFI files | https://github.com/mozilla/uniffi-rs |
| GRDB.swift | MIT | Notice | https://github.com/groue/GRDB.swift |
| Sparkle | MIT | Notice | https://github.com/sparkle-project/Sparkle |
| Parakeet TDT 0.6B V2 / V3 weights | CC-BY-4.0 | Attribution to NVIDIA in model manager + credits | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |
| Whisper small/medium/large-v3 weights | Apache-2.0 (HF card) / MIT (openai/whisper repo) | Notice | https://huggingface.co/openai/whisper-small |
| Whisper large-v3-turbo | MIT | Notice | https://huggingface.co/openai/whisper-large-v3-turbo |
| SenseVoice Small | FunASR Model License (custom, permits commercial use with attribution) | Attribution; show licence link before download | https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE |
| Moonshine base | MIT | Notice | https://huggingface.co/handy-computer/moonshine-base-gguf |
| GGUF conversions (`handy-computer/*-gguf`) | inherit upstream licence (HF tags match the table above) | as upstream | https://huggingface.co/handy-computer |
