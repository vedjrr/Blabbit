# GOAL — Definition of Done

The loop ends only when every box below is checked **with evidence** recorded in `PROGRESS.md`. Items marked (H) need a human to perform or confirm; Claude prepares everything and asks.

## G0. Handy parity (feature-for-feature)
- [ ] `docs/PARITY.md` exists: every user-facing feature, setting, supported model and shortcut behaviour in the current Handy release (from its source code, README and releases, with links), each marked Matched / Better / Not applicable (with reason).
- [ ] Zero rows left "Missing" at DONE. New Handy features found later get added as rows.
- [ ] (H) Side-by-side test: same machine, same model, same 5 fixture clips, Handy vs Utter. Latency and word error rate recorded in `docs/BENCHMARKS.md`. Utter is equal or better on both.

Parity means the same features and the same feel. It does not mean copying Handy's code, name, icon or UI assets. Handy is MIT-licensed, so reading its code is fine and reusing a snippet is allowed with the MIT notice kept, but our UI and branding must be our own.

## G1. Core dictation
- [ ] Hold hotkey → recording starts in < 50 ms (logged: key-down → first audio buffer).
- [ ] Release → text inserted at cursor. Target p50 (release → insert done) for a 5 s utterance on Parakeet V3: < 700 ms on M1+. Record real numbers whatever they are.
- [ ] Model loads at launch in background, warms up, stays resident. Log shows exactly one load per session unless the user switches model.
- [ ] Push-to-talk and toggle modes both work. Hotkey configurable, does not leak keystrokes into the focused app.
- [ ] Recordings < 0.3 s or pure silence produce no insertion and no error popup.
- [ ] 5-minute recording transcribes without crash or truncation.

## G2. Text insertion
- [ ] Strategy chain: AX `kAXSelectedTextAttribute` → clipboard + synthetic ⌘V → per-char CGEvent unicode typing. Per-app table, user-overridable.
- [ ] Clipboard (all pasteboard types) restored after paste insertion.
- [ ] Secure input detected (`IsSecureEventInputEnabled`) → no insertion, subtle overlay notice.
- [ ] (H) `docs/TEST_CHECKLIST.md` passes in: TextEdit, Notes, Safari, Chrome, Arc, VS Code, Cursor, Xcode, Terminal, iTerm2, Slack, Discord, WhatsApp, Messages, Mail, Notion, ChatGPT web.

## G3. Models
- [ ] Model manager: browse, download (resumable, HTTP range), pause/cancel/retry, SHA-256 verify, delete, set default; shows size, languages, status.
- [ ] Rust `SpeechModel` trait: `load`, `unload`, `transcribe`, `metadata`, `supported_languages`, `memory_requirements`.
- [ ] Each model is either **verified** (real transcription of `fixtures/audio/*.wav`, WER vs reference recorded) or listed **unsupported with reason**: Parakeet TDT 0.6B V3, Parakeet V2, Whisper Small, Medium, Large-v3, Large-v3-Turbo, SenseVoice Small, Moonshine Base.
- [ ] Switching models unloads the old one; RSS drop measured.
- [ ] Corrupt/partial file → clear error + one-click re-download.

## G4. Processing pipeline
- [ ] `RawTranscript → [Processors] → FinalText`, each stage pure and unit-tested.
- [ ] Modes: Exact, Clean, Professional, Code, Custom. Exact/Clean/Code need no LLM. Professional/Custom use an optional `TextProcessor` (Ollama + one cloud provider; cloud off by default, key in Keychain).
- [ ] Personal vocabulary: fuzzy post-correction with threshold, plus Whisper initial prompt where supported. Tested with: HoldMyCode, Decivra, Maynooth, PostgreSQL, TypeScript, SwiftUI, WhisperKit.

## G5. App shell
- [ ] Menu bar: Start/Stop, current model, mode, microphone, Model Manager, History, Settings, shortcut, Quit.
- [ ] Non-activating overlay NSPanel: never steals focus; level meter, timer, processing state; shows within one frame of key-down.
- [ ] Settings: General, Dictation, Models, Audio, Text Insertion, Language, Privacy (all fields from `docs/BRIEF.md` §10).
- [ ] History (SQLite/GRDB): timestamp, duration, model, raw, final; search, copy, delete, delete all, disable. No audio kept unless enabled.
- [ ] Permission onboarding for Microphone + Accessibility with deep links and live re-check.
- [ ] Every failure in BRIEF §16 maps to a plain-English message; a test enumerates them.
- [ ] Mic disconnect / Bluetooth route change mid-recording handled without crash.

## G6. Quality
- [ ] `make test` green: audio resampling, model load, fixture transcription, downloads (local HTTP test server), processors, settings persistence, history, insertion strategy selection, clipboard restore, error mapping.
- [ ] `make bench` writes JSON: launch time, model load, warm-up, key-down→capture, RTF per model, insert latency, peak RSS, CPU%. Table in `docs/BENCHMARKS.md` with machine spec.
- [ ] (H) No network traffic during dictation (`nettop` log attached).
- [ ] Critic subagent final review: zero BLOCKERs.

## G7. Distribution
- [ ] Hardened runtime; entitlements minimal and justified in ARCHITECTURE.md.
- [ ] `make dmg`: build → sign → notarise (`notarytool`) → staple → DMG. (H) run with real Developer ID.
- [ ] Sparkle 2 feed with EdDSA signing.
- [ ] Original app icon, `README.md`, `docs/RELEASING.md`, Homebrew Cask draft, uninstall instructions (app + `~/Library/Application Support/Utter` + models).

## G8. Better than Handy (where it's measurable)
Handy is cross-platform (Tauri + web UI). Utter is Mac-only and native, so it should win in these areas. Each one needs a number or a demo:
- [ ] Lower idle RAM and faster app launch than Handy (measured side by side).
- [ ] Native SwiftUI/AppKit settings, overlay and menu, following macOS conventions (no web view).
- [ ] Smarter insertion: per-app strategy table, full clipboard restore, secure-field detection. Demonstrate apps where Handy's insertion fails and Utter's works, or show they are equal.
- [ ] Personal vocabulary correction and the Clean/Professional/Code/Custom modes. Check in M0 which of these Handy already has and record it in PARITY.md.
- [ ] Searchable history with raw and final text side by side.
- [ ] Any other improvement is logged in PARITY.md as "Better" with evidence. Only claim "better" when it's measured.

## Completion
When all non-(H) boxes are checked with evidence and every (H) item is either confirmed or listed under `## Blocked on human`, set line 1 of `PROGRESS.md` to `STATUS: DONE`. Only then may the loop stop.
