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
- M0 gate: re-run critic after fixing the first review's findings (1 BLOCKER, 4 MAJOR). Then merge branch `m1-draft` (Rust engine, utter-cli, FFI already drafted in isolation) and continue M1.

## Done (with evidence)
- [M0] Handy cloned read-only to `/tmp/handy-ref` (v0.9.7-6-g8f9cf53). Component map → `docs/ARCHITECTURE.md` §1.
- [M0] `docs/PARITY.md` written: 92 feature rows across dictation, insertion, models, post-processing, history, app shell, plus the G8 "does Handy already have it" table. Sources are file paths, `S.field` settings or Tauri command names; "—" marks Utter-only rows.
- [M0] Licences checked (HF API + GitHub API + crates.io) → `docs/ARCHITECTURE.md` §3.
- [M0] Runtime hypothesis tested: `transcribe-cpp` 0.2.3 (ggml + Metal) runs both Parakeet V3 and Whisper Small on Metal.
  `$ core/target/release/examples/runtime_probe <model.gguf> fixtures/audio/tts_0*.wav` → `evidence/m0/runtime_probe.log`
  Parakeet V3 Q8_0: load 261 ms, warm-up 102 ms, infer 93–129 ms per ~4.6 s clip (RTF 0.019–0.028). Whisper Small Q8_0: infer 406–445 ms (RTF 0.084–0.099).
- [M0] Model downloads verified: `shasum -a 256` of Parakeet V3 Q8_0 = `5859f779…2cc7`, Whisper Small Q8_0 = `9b9c8811…b860` (equal to pinned catalog hashes).
- [M0] ARCHITECTURE.md has 11 ADRs, each with a sources line.
- [M0] Runtime tested for **all four GOAL families** on Metal, same 5 clips (critic BLOCKER fix): SenseVoice Small 54–67 ms (RTF ≤ 0.014), Moonshine Base 88–194 ms (RTF ≤ 0.042) → `evidence/m0/runtime_probe_families.log`. SHA-256 of both downloads equals the pinned hashes (`6c759ee4…`, `7f0027df…`).
- [M0] ONNX alternative measured, not assumed: Parakeet V3 int8 via transcribe-rs/ort (CPU) 168–194 ms vs GGUF-Metal 79–85 ms on the same clips → `evidence/m0/onnx_vs_gguf_parakeet.log`.
- [M0] First-load cost measured: 7215 ms on the first run of a fresh binary, then 210 ms and 224 ms → `evidence/m0/first_load.log`.
- [M0] `make bench` → `Wrote bench/results/2026-09-24.json` (4 models × load/warm-up + 5 clips each, machine spec). `make dmg` exists; without credentials it exits 2 with "Cannot make a release DMG: set UTTER_DEVELOPER_ID…" (real sign → hdiutil → notarytool → stapler chain in `scripts/make-dmg.sh`).
- [M0] Dev builds are signed with the local "Apple Development" identity (`codesign -dv` → `flags=0x10000(runtime)`), so TCC grants survive rebuilds.
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
- Linker: `MACOSX_DEPLOYMENT_TARGET=14.0` in `core/.cargo/config.toml` only (verified `otool -l` → `minos 14.0` on ggml objects) and `-C default-linker-libraries=yes` (compiler-rt for ggml `@available`).
- 2026-09-24: Exporting `MACOSX_DEPLOYMENT_TARGET` to `swift test` breaks Swift Testing macros under the CLT ("plugin for module 'TestingMacros' not found"). Reproduced both ways; the Makefile no longer exports it.
- 2026-09-24: The Moonshine non-English variants are under the Moonshine AI Community License upstream, not MIT as Handy's catalog says (ARCHITECTURE §3).
- 2026-09-24: The first critic run was cut off by an API usage limit and gave no verdict. Re-run verdict: FAIL (1 BLOCKER: SenseVoice/Moonshine not tested; MAJOR: ONNX unmeasured, first-load unlogged, no bench/dmg targets, AX on the main thread). All fixed above.
