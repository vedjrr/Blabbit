# Milestones

Work strictly in order. Each has an **exit gate**; do not start the next until the gate passes and the critic has no BLOCKERs.

## M0 — Research & decisions (no app code yet)
- Clone https://github.com/cjpais/Handy into `/tmp/handy-ref` (read-only reference). Map: audio capture, hotkey, insertion, model manager, model list + URLs, inference crates, overlay, settings.
- Write `docs/PARITY.md`: a table of every Handy feature (source file or link, how Handy does it, our plan, status). This is the checklist for "same app as Handy". Add a column noting where we can do better.
- Check licenses: Handy (MIT), transcribe-rs, whisper.cpp / whisper-rs, sherpa-onnx, ONNX Runtime, each model's weights (Parakeet CC-BY-4.0, Whisper MIT, SenseVoice, Moonshine).
- Decide runtime per model family. Starting hypothesis to test, not assume: whisper.cpp (Metal) for Whisper; ONNX Runtime (CoreML EP) or transcribe-rs for Parakeet/SenseVoice/Moonshine.
- Write `docs/ARCHITECTURE.md` with ADRs: Swift↔Rust boundary (UniFFI vs C ABI), runtime choices, insertion strategy, model storage layout, threading model.
- Scaffold repo: Cargo workspace `core/`, Xcode project `app/`, `Makefile`, `.gitignore`, fixtures.
- **Gate:** `make build` and `make test` run (even if tests are few); ARCHITECTURE.md has ≥ 5 ADRs with sources.

## M1 — Vertical slice (the one that matters)
Hotkey → mic → Parakeet V3 (or Whisper Small if Parakeet is blocked) → text in TextEdit.
- Rust core: load model once, `transcribe(pcm_f32_16k)`. CLI `blabbit-cli file.wav` for testing without UI.
- Swift: status item, CGEventTap push-to-talk, AVAudioEngine capture → 16 kHz mono f32, clipboard-paste insertion.
- **Gate:** fixture WAV transcribes via CLI with recorded WER; (H) human confirms spoken sentence lands in TextEdit; latency logged.

## M2 — Insertion reliability
AX insertion, CGEvent typing fallback, per-app strategy table, clipboard restore, secure-field detection, `TEST_CHECKLIST.md`.
- **Gate:** G2 automated items pass; checklist written.

## M3 — Model manager + all models
Registry JSON, resumable downloader with SHA-256, UI, switching with unload, adapters for each family. Verify or mark unsupported every model in G3.
- **Gate:** G3 fully satisfied.

## M4 — Overlay, audio robustness, permissions
NSPanel overlay, device selection, route-change/disconnect handling, silence/short/long recordings, onboarding.
- Carried from M2: the G2 "subtle overlay notice" for blocked (secure input) and unverified insertions moves into the overlay. Until then, M2 shows it as a 4 s menu bar icon change with the message as tooltip and in the menu (`InsertionOutcome`/`AttentionCue`).
- **Gate:** G1 + G5 overlay/permissions/audio items pass.

## M5 — Processing, vocabulary, history, settings
Pipeline + modes, vocabulary, TextProcessor providers, GRDB history, full settings, error mapping.
- **Gate:** G4 + remaining G5 pass.

## M6 — Benchmarks & performance pass
`blabbit-bench`, BENCHMARKS.md, profile with Instruments where needed, fix the slowest stage.
- **Gate:** G6 pass.

## M7 — Distribution & polish
Icon, signing, notarisation script, Sparkle, DMG, Cask, README, RELEASING, uninstall.
- **Gate:** G7 pass → final critic review → `STATUS: DONE`.
