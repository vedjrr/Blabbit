STATUS: IN_PROGRESS

# Progress (loop state — Claude owns this file)

Current milestone: M0 (gate review)
Iteration: 1

## Environment (verified 2026-09-24)
- Apple M4, 16 GB, macOS 27.0 (26A428), arm64.
- **Xcode.app NOT installed** — only Command Line Tools (Swift 6.4, SwiftPM, Swift Testing, codesign, notarytool, stapler). Build uses SwiftPM + Makefile (ADR-001).
- Rust was not installed; installed rustup → rustc 1.98.1, cargo 1.98.1 (`~/.cargo`). cmake 4.4.3 installed via Homebrew (needed by transcribe-cpp-sys).
- Repo was not a git repo; `git init` done, author = Vedjr02.

## Next task
- M0 gate: run critic, fix BLOCKERs, then start M1 (Rust `Engine` + `utter-cli file.wav` with WER).

## Done (with evidence)
- [M0] Handy cloned read-only to `/tmp/handy-ref` (v0.9.7-6-g8f9cf53). Component map → `docs/ARCHITECTURE.md` §1.
- [M0] `docs/PARITY.md` written: 88 feature rows (A1–F22) across dictation, insertion, models, post-processing, history, app shell, plus the G8 "does Handy already have it" table. Every row has a Handy source link.
- [M0] Licences checked (HF API + GitHub API + crates.io) → `docs/ARCHITECTURE.md` §3.
- [M0] Runtime hypothesis tested: `transcribe-cpp` 0.2.3 (ggml + Metal) runs both Parakeet V3 and Whisper Small on Metal.
  `$ core/target/release/examples/runtime_probe <model.gguf> fixtures/audio/tts_0*.wav` → `evidence/m0/runtime_probe.log`
  Parakeet V3 Q8_0: load 261 ms, warm-up 102 ms, infer 93–129 ms per ~4.6 s clip (RTF 0.019–0.028). Whisper Small Q8_0: infer 406–445 ms (RTF 0.084–0.099).
- [M0] Model downloads verified: `shasum -a 256` of Parakeet V3 Q8_0 = `5859f779…2cc7`, Whisper Small Q8_0 = `9b9c8811…b860` (equal to pinned catalog hashes).
- [M0] ARCHITECTURE.md has 11 ADRs with sources.
- [M0] Scaffold: `core/` Cargo workspace (utter-core, utter-cli, utter-ffi, uniffi-bindgen), `app/` SwiftPM (UtterFFI, UtterCore, Utter, UtterTests), `Makefile`, `.gitignore`, fixtures.
- [M0] `make build` → `Built …/build/Utter.app`; `build/Utter.app/Contents/MacOS/Utter --version` → `Utter transcribe-cpp 0.2.3 (unknown)`; `codesign -dv` → `flags=0x10002(adhoc,runtime)`, entitlement `com.apple.security.device.audio-input`.
- [M0] `make test` → Rust `test result: ok. 2 passed` (runtime version, Metal backend compiled in); Swift `Test run with 1 test … passed` (Rust core linked into Swift).
- [M0] Fixtures: `scripts/make-tts-fixtures.sh` generates 5 clips (4.3–5.1 s, 16 kHz mono) with macOS `say` + reference `.txt`; includes vocab words HoldMyCode, PostgreSQL, Maynooth, SwiftUI, TypeScript.

## Blocked on human
- (non-blocking, wanted before M1 gate) **Record your own voice fixtures.** The TTS clips are synthetic. Please record 3–5 clips (~5 s each), save as `fixtures/audio/human_NN.wav` with the exact words in `human_NN.txt`. Quick way: QuickTime → New Audio Recording, export, then `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a fixtures/audio/human_01.wav`. Include: "Testing Utter, one two three. HoldMyCode uses PostgreSQL." and a sentence with Decivra, Maynooth, TypeScript, SwiftUI, WhisperKit.
- (optional) Install Xcode.app if you want Instruments profiling in M6; the build does not need it.

## Proposed goal changes
- CLAUDE.md says `make test` = `cargo test` + `xcodebuild test`. Xcode is not installed, so `make test` runs `swift test` (Swift Testing) instead. Same coverage, and it works with or without Xcode. (ADR-001)

## Notes / decisions log
- 2026-09-24: Handy moved nearly every model to GGUF via transcribe-cpp; we follow (ADR-002) after measuring it ourselves.
- 2026-09-24: The first-ever Parakeet load took 7.7 s (one-time Metal pipeline compile by the OS); later cold-process loads took 230–260 ms. Launch-time budget must allow for the first-run case.
- Linker: `MACOSX_DEPLOYMENT_TARGET=14.0` (Makefile + `core/.cargo/config.toml`) and `-C default-linker-libraries=yes` (compiler-rt for ggml `@available`).
