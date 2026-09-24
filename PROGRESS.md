STATUS: IN_PROGRESS

# Progress (loop state — Claude owns this file)

Current milestone: M2 — insertion reliability
Iteration: 3

## Environment (verified 2026-09-24)
- Apple M4, 16 GB, macOS 27.0 (26A428), arm64.
- **Xcode.app NOT installed** — only Command Line Tools (Swift 6.4, SwiftPM, Swift Testing, codesign, notarytool, stapler). Build uses SwiftPM + Makefile (ADR-001).
- Rust was not installed; installed rustup → rustc 1.98.1, cargo 1.98.1 (`~/.cargo`). cmake 4.4.3 installed via Homebrew (needed by transcribe-cpp-sys).
- Repo was not a git repo; `git init` done, author = Vedjr02.

## Next task
- M2 gate: critic re-review after fixing review #1 (4 BLOCKERs). Then merge branch `m3` (downloader + catalog + all 8 G3 models verified, already built in isolation) and continue M3 (FFI + Model Manager window).

## Decisions by the human
- 2026-09-24: The human **deferred the M1 voice/TextEdit gate to the end** ("model testing can be done later on at the end of the app… go ahead with the next step"). M1's automated gate is passed (critic PASS); the (H) item moves to the final human checklist and no longer blocks M2+. Deviation from CLAUDE.md rule 6, made at the human's direction.

## Milestones
- [x] **M0 — Research & decisions.** Critic re-review: `VERDICT: PASS`, zero BLOCKERs (2026-09-24). Its 3 MAJOR and all minor findings fixed in 08f14b8 (bench fails loudly, `make models`, `make dmg` preflight, ONNX bench committed at `evidence/m0/onnxbench/`, CoreML EP measured, first-load cause marked unconfirmed).
- [x] M1 — Vertical slice (automated). Critic re-review `VERDICT: PASS`; its 4 MAJORs fixed in 01a38e5. (H) TextEdit test deferred by the human to the end (see Decisions).
- [ ] M2 — Insertion reliability. Built (see Done); critic review pending. Live per-app checklist (H) deferred with the other human checks.

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
- [M0] ONNX alternative measured, not assumed: Parakeet V3 int8 via transcribe-rs/ort (CPU) 168–194 ms vs GGUF-Metal 79–85 ms on the same clips (≈1.8–2.1×) → `evidence/m0/onnx_vs_gguf_parakeet.log`, source in `evidence/m0/onnxbench/`.
- [M0] First-load outlier logged: 7215 ms once, then 210/224 ms → `evidence/m0/first_load.log` (cause unconfirmed; not reproducible by the critic).
- [M0] `make bench` → `Wrote bench/results/2026-09-24.json (24 rows)` (4 models × load/warm-up + 5 clips each, machine spec, git rev); fails with exit 1 and writes nothing if any model fails (checked with a random-bytes .gguf).
- [M0] ONNX Runtime CoreML EP measured too: 227–260 ms per clip, slower than the CPU EP → `evidence/m0/onnx_vs_gguf_parakeet.log`. `make dmg` exists; without credentials it exits 2 with "Cannot make a release DMG: set UTTER_DEVELOPER_ID…" (real sign → hdiutil → notarytool → stapler chain in `scripts/make-dmg.sh`).
- [M0] Dev builds are signed with the local "Apple Development" identity (`codesign -dv` → `flags=0x10000(runtime)`), so TCC grants survive rebuilds.
- [M0] Scaffold: `core/` Cargo workspace (utter-core, utter-cli, utter-ffi, uniffi-bindgen), `app/` SwiftPM (UtterFFI, UtterCore, Utter, UtterTests), `Makefile`, `.gitignore`, fixtures.
- [M0] `make build` → `Built …/build/Utter.app`; `build/Utter.app/Contents/MacOS/Utter --version` → `Utter transcribe-cpp 0.2.3 (unknown)`; `codesign -dv` → `flags=0x10000(runtime)` (signed Apple Development; ad-hoc `0x10002` when no identity), entitlement `com.apple.security.device.audio-input`.
- [M0] `make test` → Rust `test result: ok. 2 passed` (runtime version, Metal backend compiled in); Swift `Test run with 1 test … passed` (Rust core linked into Swift).
- [M0] Fixtures: `scripts/make-tts-fixtures.sh` generates 5 clips (4.3–5.1 s, 16 kHz mono) with macOS `say` + reference `.txt`; includes vocab words HoldMyCode, PostgreSQL, Maynooth, SwiftUI, TypeScript.

- [M1] Rust core: `SpeechModel` trait (load/unload/transcribe/metadata/supported_languages/memory_requirements), `GgufModel`, resident `Engine` (unloads old model before loading new), short/silent skip, plain-English `UtterError`, WER. `utter-cli` transcribes WAVs → `evidence/m1/cli_fixtures.log`: Parakeet V3 p50 79–86 ms per ~4.6 s clip (RTF 0.017–0.019), **aggregate WER 0.258** (16/62, misses are custom vocab words: HoldMyCode, PostgreSQL, SwiftUI, Maynooth); Whisper Small p50 383–417 ms, WER 0.161; `model_loads=1` for both.
- [M1] Whisper initial prompt with the vocabulary list: Whisper Small WER 0.161 → **0.032** (`utter-cli --prompt "Utter, HoldMyCode, PostgreSQL, Maynooth, SwiftUI, TypeScript, Decivra, WhisperKit"`).
- [M1] 5-minute recording: `cargo test -p utter-core --test fixtures five_minute` → audio_ms=300000, inference 15.1 s, 695/658 words, WER 0.299, tail present (no truncation).
- [M1] `make test`: Rust 14 unit + 2 real-model tests; Swift 20 tests in 4 suites (shortcut matcher, clipboard snapshot + receipt-based restore + "don't clobber newer copy", resampler 48/44.1/24/16 kHz → 16 kHz mono with frequency and level checks, Swift→Rust bridge transcription with `loadCount()==1`, plain-English errors).
- [M1] FFI cost: 5 min PCM round trip 27.5 ms (≈ 0.5 ms per 5 s utterance).
- [M1] Critic M1 review #1 → FAIL. Fixed:
  (BLOCKER) status queries no longer take the model lock (`AtomicBool` + separate `RwLock` info): 2.7 M polls during a live inference, worst 106 µs → `evidence/m1/real_model_tests.log`; Swift tracks `modelLoaded` itself.
  (MAJOR) dictations can't overlap (presses accepted only when idle; inserts serialised, test added).
  (MAJOR) capture rewritten on `AVAudioSinkNode`: IO-sized callbacks, RT thread only downmixes into a preallocated ring, all conversion on one serial queue, and stop waits (≤150 ms) for audio up to the release instant, so the tail is kept. Rebuilds on `AVAudioEngineConfigurationChange` or start failure. Ring tests: wrap, overflow count, tail signal, 201,600-sample concurrent producer/consumer with nothing lost.
  (MAJOR) pasteboard privacy (macOS 15.4+ `accessBehavior` logged at launch): an unreadable clipboard is never "restored"/wiped; the user is told.
  (MAJOR) latency fields are split: keydown→record started / first sample / first callback, release→last sample, transcribed, paste sent, target read, restored.
  (MAJOR) early-reader receipt: quiet period raised to 400 ms (restore timing does not delay the text), front app and read count logged.
  (MINOR) ⌘V posted with local keyboard suppression; tap invalidated on stop; prepare runs on the audio queue; transcribe.cpp stderr noise routed to `log`; evidence files added.
- [M1] Critic M1 review #2 → PASS. MAJORs fixed anyway (01a38e5):
  - The ring drain copies outside the lock, so nothing allocates while the RT thread might wait.
  - Clipboard is read only when macOS reports "always allow" (else it is left with the transcript as plain text; no per-dictation alerts). A partial/declined/oversize read is unreadable and never restored. The snapshot is read off the main thread.
  - Recording watchdog: key not physically down ×2, or secure input → release; 10-min hard cap; the matcher is reset so Space is never left swallowed.
  - Minors: mic-denied state persists, a failed start + release keeps the failure, device change mid-recording is reported, oversize IO buffers and resampler errors are counted/logged, ADR-008 rewritten.
- [M1] Tests at 01a38e5: Rust 14 unit + 3 real-model; Swift 34 tests in 6 suites.
- [M1] Evidence re-recorded at 01a38e5: `evidence/m1/real_model_tests.log` (5-min: 300000 ms audio, 14.8 s, 695/658 words, WER 0.299; status polls 2.7 M, worst 241 µs), `evidence/m1/whisper_prompt.log` (WER 0.032), `evidence/m1/app_launch_idle.log` (tap started, audio graph 48 kHz, `model_load load_ms=218 warmup_ms=44 load_count=1`, RSS 917 MB, CPU 0.1 %).
- [M1] App launch after fixes (`evidence/m1/app_launch_idle.log`): tap started, `audio graph ready input_rate=48000 channels=1`, `pasteboard access_behavior=2`, `model_load … load_count=1`; idle RSS 835 MB, CPU 0.1 %.
- [M1] App launch, first build (`evidence/m1/app_launch.log`): model loads in the background at launch, `load_count=1`; first launch of a new build `load_ms=7303` (the ~7 s outlier again: seen on every fresh build of the app or CLI), relaunch of the same build `load_ms=192 warmup_ms=57 total_ms=250`. Idle: RSS 922 MB, CPU 0.1 %.

- [M2] Insertion strategy chain (ADR-006), `app/Sources/UtterKit/{InsertionStrategy,AccessibilityInserter,TypingInserter,TextInserter,InsertionSettings,SecureInputMonitor}.swift`:
  - Per-app table (native → AX, paste, type; terminals/browsers/Electron → paste, type; unknown → AX, paste, type). User overrides are persisted (`insertion.overrides`). Bundle IDs checked against the apps installed here (ChatGPT here is `com.openai.codex`).
  - AX insertion only where the value is readable, with read-back verification: `inserted` / `noEffect` (falls through) / `unverified` (never retried, so no duplicate text). Runs on its own AX queue with a 0.25 s messaging timeout.
  - Unicode typing fallback: ≤ 20 UTF-16 units per event on grapheme boundaries, newlines as Return.
  - Secure input: global check + AX `AXSecureTextField` check block every strategy. Sustained secure input → Carbon hotkey fallback (PARITY A8) and a menu notice.
  - Insertion settings (PARITY B2/B3/B6/B7/B8): clipboard-only, external script (stdin, time limit), copy-to-clipboard, auto-submit Enter/⌃Enter/⌘Enter, trailing space, paste delay. Decoding tolerates missing keys.
- [M2] Critic review #1 → FAIL (4 BLOCKERs), all fixed:
  (1) An AX write that errors or applies late can't double-insert: re-read, 150 ms settle, re-read, fall through only if readable and unchanged; fakes `failButApply`/`applyOnSecondRead`.
  (2) The external script can't crash or hang Utter: `F_SETNOSIGPIPE`, our read end closed, `write(contentsOf:)` on its own queue, SIGTERM → SIGKILL; tests with a ~280 KB write to a script that exits immediately and a TERM-ignoring script.
  (3) The Carbon fallback is coherent: the watchdog only cuts *tap* recordings for secure input; under secure input the text goes to the clipboard with a notice (dropped if a password field is focused).
  (4) Secure input has automated evidence: an injected probe, and every method is blocked with the clipboard untouched (parameterised test).
  MAJORs/minors fixed: unknown-app AX also settles; Carbon double-free on failed init; hotkey ID check; re-register on shortcut change; timers in common modes; auto-submit skipped for unverified/script; B8 after-delay + ordering test; oversize graphemes split on scalar boundaries; local-key suppression while typing; the secure notice no longer clobbers other messages; failed insertion leaves the text on the clipboard; AX host startup timeout; production `current()` path test with a pid safety check. Deferred: the G2 "overlay notice" is menu text until the overlay exists (M4).
- [M2] Tests: Swift 79 in 15 suites (3 AX integration tests skipped: screen locked); Rust 14 + 3. The real-AppKit AX integration tests (`AXIntegrationTests`, helper `UtterAXHost` with a real NSTextView/NSSecureTextField) are **skipped while the screen is locked** (`CGSSessionScreenIsLocked=1`; the window server then exposes no window contents to AX). Three attempts confirmed this, then I changed approach to an explicit skip. They run automatically in an unlocked session.
- [M2] `docs/TEST_CHECKLIST.md`: an expected strategy per app, how to read the `dictation` log line, a secure-keyboard-entry check, and a verified `defaults write` override recipe. PARITY: 15 rows now **Built**.

## Blocked on human
- **Required once (takes 2 minutes, no voice needed):** with the Mac unlocked, run `cd "/Users/ved/Documents 2/utter-kit" && make test`. Three real-Accessibility tests (`AXIntegrationTests`) only run on an unlocked screen, and they are the only proof the AX layer works against real AppKit controls. A test window will flash briefly.
- **Deferred to the end (by your choice):** run `docs/TEST_CHECKLIST.md` across the apps.
- **Deferred to the end (by your choice): live dictation into TextEdit** (needs your voice). Utter (build 01a38e5) is **already running**: its log shows the shortcut active (Accessibility is granted) and the microphone graph ready. If it isn't running: `cd "/Users/ved/Documents 2/utter-kit" && make build && open build/Utter.app`. A waveform icon appears in the menu bar.
  2. Grant **Accessibility**: System Settings → Privacy & Security → Accessibility → enable **Utter** (use the + button and pick `build/Utter.app` if it is not listed). Grant **Microphone** when prompted (or System Settings → Privacy & Security → Microphone → Utter).
  3. Click the Utter menu bar icon → **Retry Shortcut** (or quit and reopen Utter). The menu should say "Ready", with no "Allow Accessibility Access…" item.
  4. Open TextEdit, new document. Copy the word `SENTINEL` to the clipboard.
  5. Hold **⌥ Space**, say "Testing Utter, one two three. HoldMyCode uses PostgreSQL.", release.
  6. Check that the text appears in TextEdit and no space character or "…" was typed by the shortcut. Then press ⌘V somewhere: it should paste `SENTINEL`. If macOS shows an **"Allow Paste"** alert for Utter, choose **Allow** (or set Utter to "Allow" under System Settings → Privacy & Security → Paste from Other Apps); Utter needs it to put your clipboard back.
  Use the built-in microphone for this first test.
  Optional: `swift scripts/e2e-textedit.swift /tmp/utter-e2e.txt fixtures/audio/tts_01.wav` runs the same path automatically (synthetic ⌥Space plus the clip played through the speakers). I could not run it: the screen was locked (frontmost app `loginwindow`).
  7. Repeat 3–5 times with ~5 s sentences, then run `/loop did the M1 TextEdit test: <what you saw>`. I'll read the `dictation … keydown_to_first_sample_ms … release_to_insert_done_ms` lines in `~/Library/Logs/Utter/utter.log`.
  (Signing uses your local "Apple Development" identity, so these grants survive rebuilds.)
- (non-blocking, wanted before M1 gate) **Record your own voice fixtures.** The TTS clips are synthetic. Please record 3–5 clips (~5 s each), save as `fixtures/audio/human_NN.wav` with the exact words in `human_NN.txt`. Quick way: QuickTime → New Audio Recording, export, then `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a fixtures/audio/human_01.wav`. Include: "Testing Utter, one two three. HoldMyCode uses PostgreSQL." and a sentence with Decivra, Maynooth, TypeScript, SwiftUI, WhisperKit.
- (optional) Install Xcode.app if you want Instruments profiling in M6; the build does not need it.

## Proposed goal changes
- CLAUDE.md says `make test` = `cargo test` + `xcodebuild test`. Xcode is not installed, so `make test` runs `swift test` (Swift Testing) instead. Same coverage, and it works with or without Xcode. (ADR-001)

## Notes / decisions log
- 2026-09-24: Handy moved nearly every model to GGUF via transcribe-cpp; we follow (ADR-002) after measuring it ourselves.
- 2026-09-24: A ~7 s first model load was observed three times (7.7 s, 7538 ms, 7215 ms); later loads took 210–260 ms. The cause (likely a Metal pipeline compile) is **unconfirmed**; the critic could not reproduce it. The app shows "Preparing model…" as a precaution.
- Linker: `MACOSX_DEPLOYMENT_TARGET=14.0` in `core/.cargo/config.toml` only (verified `otool -l` → `minos 14.0` on ggml objects) and `-C default-linker-libraries=yes` (compiler-rt for ggml `@available`).
- 2026-09-24: "plugin for module 'TestingMacros' not found" was **misdiagnosed** at first as a `MACOSX_DEPLOYMENT_TARGET` effect. After more runs it proved to be intermittent failure of SwiftPM's default swiftbuild backend under the CLT: independent of env/PATH/-j1, and it also caused "unable to resolve Swift module dependency". Three approaches failed, so I changed approach: the Makefile uses `--build-system native` + CLT `Testing.framework` paths → 7/7 green full recompiles.
- 2026-09-24: Flaky test found by 10× reruns: `overlappingInsertsAreSerialisedAndRestoreTheOriginal` assumed the start order of `async let`; it now asserts no interleaving instead of order.
- 2026-09-24: The Moonshine non-English variants are under the Moonshine AI Community License upstream, not MIT as Handy's catalog says (ARCHITECTURE §3).
- 2026-09-24: The first critic run was cut off by an API usage limit and gave no verdict. Re-run verdict: FAIL (1 BLOCKER: SenseVoice/Moonshine not tested; MAJOR: ONNX unmeasured, first-load unlogged, no bench/dmg targets, AX on the main thread). All fixed above.
