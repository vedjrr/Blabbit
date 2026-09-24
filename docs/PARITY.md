# Handy ↔ Utter parity

Reference: Handy **v0.9.7** (latest release, 2026-09-18, https://github.com/cjpais/Handy/releases/tag/v0.9.7), source at `8f9cf53` (main, 2026-09-19).
`H/` = `https://github.com/cjpais/Handy/blob/8f9cf53cd1410cda26beea39ff802ac306e39585/`. `S.x` = field `x` of `AppSettings` in `H/src-tauri/src/settings.rs`.

Status: **Missing** (not built yet) · **Matched** (same behaviour, evidence linked) · **Better** (measured win, evidence linked) · **N/A** (reason given).
Nothing may be Missing at DONE. New Handy features found later get new rows.
Sources are file paths (with line where useful), a settings field `S.x`, or a Tauri command name (all defined under `H/src-tauri/src/commands/` unless another file is given). Rows marked "—" in the source column are Utter-only features Handy does not have.

## A. Dictation and shortcuts

| # | Feature | Handy source | How Handy does it | Utter plan | M | Status | Can we do better? |
|---|---|---|---|---|---|---|---|
| A1 | Push-to-talk (hold to record, release to transcribe) | `H/src-tauri/src/shortcut/mod.rs`, `S.shortcut_activation` | handy-keys CGEventTap or Tauri global-shortcut | Active CGEventTap, swallow matching events (ADR-005) | M1 | Missing | Measure key-down → first buffer (< 50 ms target) |
| A2 | Toggle mode | `S.shortcut_activation = Toggle` | tap to start, tap to stop | Same | M4 | Missing | — |
| A3 | Hold-or-toggle hybrid with `hold_threshold_ms` | `S.hold_threshold_ms`, `HoldOrToggle` | short tap toggles, long hold is PTT | Same | M4 | Missing | — |
| A4 | Configurable shortcut incl. modifier-only and fn/Globe | `H/src-tauri/src/shortcut/handy_keys.rs:412` | handy-keys validation | Native shortcut recorder, modifier-only + fn, conflict detection with system shortcuts | M4 | Missing | Native recorder + conflict warning |
| A5 | Default shortcut `⌥ Space` on macOS | `H/src-tauri/src/settings.rs:862` | — | Same default | M1 | Missing | — |
| A6 | Cancel shortcut (Esc) while recording | `S.bindings["cancel"]` | registered only while recording | Same, swallowed only while recording | M4 | Missing | — |
| A7 | Separate "transcribe with post-processing" shortcut | `S.bindings["transcribe_with_post_process"]` | second binding | Second binding that forces the selected LLM mode | M5 | Missing | — |
| A8 | Secure-input shortcut fallback + tray warning | `H/src-tauri/src/secure_input.rs` | polls `IsSecureEventInputEnabled`, shadow-registers Carbon hotkeys | Same idea, own code (ADR-005) | M2 | Missing | Show culprit app name in overlay |
| A9 | Audio feedback sounds (start/stop), themes, custom, volume | `S.audio_feedback`, `S.sound_theme`, `S.audio_feedback_volume`, `H/src-tauri/src/audio_feedback.rs` | bundled WAVs | Own sounds (original, generated), `NSSound`/AVAudioPlayer | M4 | Missing | — |
| A10 | Mute system output while recording | `S.mute_while_recording` | — | Core Audio default-output mute + restore | M4 | Missing | — |
| A11 | Always-on microphone | `S.always_on_microphone` | stream kept open | "Keep microphone warm" option (ADR-004) | M4 | Missing | Measure latency difference |
| A12 | Microphone selection | `S.selected_microphone` | cpal device | Core Audio device picker | M4 | Missing | — |
| A13 | Input channel selection | `S.selected_channel` | pick one channel | Channel picker for multi-channel interfaces | M4 | Missing | — |
| A14 | Clamshell microphone (alternate mic when lid closed) | `S.clamshell_microphone`, `H/src-tauri/src/helpers/clamshell.rs` | IOKit clamshell state | Same via IOKit `AppleClamshellState` | M4 | Missing | — |
| A15 | Output device for feedback sounds | `S.selected_output_device` | — | Output device picker | M4 | Missing | — |
| A16 | VAD silence trimming (Silero / Earshot) | `S.vad_enabled`, `S.vad_backend`, `H/src-tauri/src/audio_toolkit/vad/` | Silero ONNX / Earshot | Energy + model VAD (Silero GGUF if transcribe.cpp supports, else energy VAD with hangover); silence-only → no insert | M4 | Missing | — |
| A17 | Extra recording buffer after release | `S.extra_recording_buffer_ms` | keeps recording N ms | Same | M4 | Missing | — |
| A18 | Live streaming transcription in overlay | `S.overlay_style = Live`, `StreamTextEvent` in `managers/transcription.rs` | transcribe-cpp streaming sessions | transcribe-cpp `Session::stream` for streaming-capable models | M4 | Missing | — |
| A19 | Language selection + auto-detect | `S.selected_language` | per-model languages | Same | M5 | Missing | — |
| A20 | Translate to English (Whisper) | `S.translate_to_english` | Whisper translate task | Same (`Task::Translate`) | M5 | Missing | — |
| A22 | Play test sound (preview feedback sound on the chosen output device) | `play_test_sound` in `H/src-tauri/src/commands/audio.rs:295` | — | "Play" button next to sound picker | M4 | Missing | — |
| A23 | Reset a shortcut to its default | `reset_binding` in `H/src-tauri/src/shortcut/mod.rs:226` | — | "Reset to ⌥Space" button | M4 | Missing | — |
| A21 | Short / silent recordings ignored | `managers/audio.rs` VAD policy | — | < 0.3 s or silence → nothing | M4 | Missing | — |

## B. Text insertion

| # | Feature | Handy source | How Handy does it | Utter plan | M | Status | Can we do better? |
|---|---|---|---|---|---|---|---|
| B1 | Paste via clipboard + ⌘V | `H/src-tauri/src/clipboard.rs:55` | enigo key chord | CGEvent ⌘V (ADR-006) | M1 | Missing | — |
| B2 | Paste method options: ⌘V, direct typing, none, Shift+Insert, Ctrl+Shift+V, external script | `S.paste_method` | enum | ⌘V, type, AX, none, external script; Shift+Insert/Ctrl+Shift+V are Windows/Linux chords | M2 | Missing | AX insertion (Handy has none) |
| B3 | Clipboard handling: don't modify / also copy to clipboard | `S.clipboard_handling` | — | Same | M2 | Missing | — |
| B4 | Clipboard restore after paste | `H/src-tauri/src/clipboard.rs:63-106` | restores text, or image only when no text | Restore every item × every type, `changeCount`-guarded | M2 | Missing | **Better**: full restore (to demonstrate) |
| B5 | Receipt-based "reliable paste" | `H/src-tauri/src/paste_tx/macos.rs` (debug-gated, `clipboard.rs:806`) | pasteboard promise read receipt | Promise receipt on by default | M2 | Missing | On by default |
| B6 | Auto-submit after paste (Enter / Ctrl+Enter / ⌘Enter) | `S.auto_submit`, `S.auto_submit_key` | sends key | Same | M2 | Missing | Per-app setting |
| B7 | Append trailing space | `S.append_trailing_space` | — | Same | M2 | Missing | — |
| B8 | Paste delays before/after | `S.paste_delay_ms`, `S.paste_delay_after_ms` | — | Same, per-app override | M2 | Missing | — |
| B9 | Secure field → no insertion | `H/src-tauri/src/secure_input.rs` | warns in tray | `IsSecureEventInputEnabled` + AX `AXSecureTextField` role check → skip, overlay notice | M2 | Missing | AX role check catches secure fields even without global secure input |
| B10 | Per-app insertion strategy table | — (Handy has one global method) | — | Bundle-ID table, user-overridable | M2 | Missing | **Better** (Handy has no per-app table) |
| B11 | Linux typing tools (wtype, xdotool, …) | `S.typing_tool` | — | — | — | N/A | Linux only |

## C. Models

| # | Feature | Handy source | How Handy does it | Utter plan | M | Status | Can we do better? |
|---|---|---|---|---|---|---|---|
| C1 | Curated catalog (69 GGUF models, pinned HF revision, SHA-256) | `H/src-tauri/src/catalog/catalog.json` | bundled JSON | Own `models.json`; only fixture-verified models marked Supported (ADR-007) | M3 | Missing | Verified-only badge + WER shown |
| C2 | Download with progress, resume (HTTP Range), SHA-256 verify | `H/src-tauri/src/managers/model/download.rs` | reqwest + hf-hub | Rust `ureq` downloader, `.partial` + sidecar | M3 | Missing | — |
| C3 | Cancel download | `cancel_download` command | — | Pause / cancel / retry | M3 | Missing | Pause (Handy has cancel only) |
| C4 | Delete model | `delete_model` | — | Same | M3 | Missing | — |
| C5 | Select / switch active model (also from tray) | `switch_active_model`, `H/src-tauri/src/tray.rs:539` | — | Same; unload old, RSS measured | M3 | Missing | — |
| C6 | Quantisation choice per model | catalog `files[]`, `default_quant` | — | Default quant + "Advanced: quant" picker | M3 | Missing | — |
| C7 | Discover local models (HF cache, custom dir) | `rescan_local_models`, `managers/model.rs:328` | scans HF cache + dir | "Add model file…" + rescan of models dir | M3 | Missing | — |
| C8 | Speed / accuracy scores, recommended flag | catalog `speed_score`, `accuracy_score` | static scores | Show **our measured** RTF + WER on this Mac | M3 | Missing | **Better**: measured, not static |
| C9 | Model unload after idle timeout | `S.model_unload_timeout` | never / immediately / 2 min … 1 h | Same | M3 | Missing | — |
| C10 | Manual unload from tray | `H/src-tauri/src/tray.rs:549` | — | Same | M3 | Missing | — |
| C11 | Accelerator / GPU device selection | `S.transcribe_accelerator`, `S.transcribe_gpu_device` | — | Auto / Metal / CPU | M3 | Missing | — |
| C12 | Parakeet TDT 0.6B V3 | catalog | GGUF Q8_0 | Verify with fixtures | M1 | Missing | — |
| C13 | Parakeet TDT 0.6B V2 | catalog | GGUF Q8_0 | Verify | M3 | Missing | — |
| C14 | Whisper Small / Medium / Large-v3 / Large-v3-Turbo | catalog | GGUF | Verify each | M3 | Missing | — |
| C15 | SenseVoice Small | catalog | GGUF Q8_0 | Verify | M3 | Missing | — |
| C16 | Moonshine Base (+ tiny, streaming variants) | catalog | GGUF Q8_0 | Verify base; others listed with status. Non-English variants are under the Moonshine AI Community License upstream (Handy's catalog says MIT) → show licence before download | M3 | Missing | Correct licence display |
| C17 | Other catalog families (Canary, Cohere, GigaAM, Granite, Qwen3-ASR, Voxtral, Fun-ASR, MedASR, MOSS, Nemotron) | catalog | GGUF | Same runtime; each verified or listed unsupported with reason | M3 | Missing | — |

## D. Post-processing

| # | Feature | Handy source | How Handy does it | Utter plan | M | Status | Can we do better? |
|---|---|---|---|---|---|---|---|
| D1 | Custom words fuzzy correction with threshold | `H/src-tauri/src/audio_toolkit/text.rs:151`, `S.custom_words`, `S.word_correction_threshold` | n-grams ≤ 3, Soundex + string similarity | Own implementation (ADR-010) + Whisper initial prompt | M5 | Missing | Measure on the 7 GOAL words |
| D2 | Filler-word removal + custom filler list | `S.filler_word_removal_enabled`, `S.custom_filler_words` | language-aware list | "Clean" mode | M5 | Missing | — |
| D3 | LLM post-processing providers (OpenAI, Z.ai, OpenRouter, Anthropic, Groq, Cerebras, Bedrock, custom OpenAI-compatible) | `H/src-tauri/src/settings.rs:650-730`, `H/src-tauri/src/llm_client.rs` | HTTP clients, keys in settings store | `TextProcessor`: Ollama + Anthropic + custom OpenAI-compatible (covers OpenAI/OpenRouter/Groq/Cerebras/Z.ai endpoints); keys in Keychain | M5 | Missing | Keys in Keychain (Handy: settings file `S.post_process_api_keys`) |
| D4 | Apple Intelligence provider | `H/src-tauri/src/apple_intelligence.rs` | FoundationModels via Swift shim | FoundationModels framework directly (on-device) | M5 | Missing | Native, no bridge |
| D5 | Prompt library (multiple saved prompts, select one) | `S.post_process_prompts`, `S.post_process_selected_prompt_id` | — | Modes: Professional, Custom (user prompts) | M5 | Missing | — |
| D6 | Modes Exact / Clean / Professional / Code / Custom | — (Handy: filler removal toggle + LLM prompts; **no Code mode, no named modes**) | — | Named modes; Exact/Clean/Code need no LLM | M5 | Missing | **Better**: Code mode + non-LLM modes |
| D7 | Chinese script conversion (OpenCC) | `ferrous-opencc` in `H/src-tauri/Cargo.toml` | — | Same idea (simplified ↔ traditional) | M5 | Missing | — |
| D9 | Per-provider LLM model selection (fetch model list from provider) | `S.post_process_models`, `fetch_post_process_models` in `H/src-tauri/src/shortcut/mod.rs:1194` | queries provider `/models` | Model picker per provider (Ollama `/api/tags`, Anthropic models list) | M5 | Missing | — |
| D8 | Output language detection | `detect_output_language` in `audio_toolkit` | whatlang | Same | M5 | Missing | — |

## E. History

| # | Feature | Handy source | How Handy does it | Utter plan | M | Status | Can we do better? |
|---|---|---|---|---|---|---|---|
| E1 | History list with transcript + post-processed text | `H/src-tauri/src/managers/history.rs:22-34` | SQLite | GRDB SQLite: timestamp, duration, model, raw, final (ADR-009) | M5 | Missing | Raw vs final side by side + FTS search (Handy has no search) |
| E2 | Play back recording audio | `get_audio_file_path` | WAV per entry, kept by default | Only if "Keep audio" enabled | M5 | Missing | Private by default |
| E3 | Star / save entries | `toggle_history_entry_saved` | — | Same | M5 | Missing | — |
| E4 | Retry transcription from history | `retry_history_entry_transcription` | — | Same (needs kept audio) | M5 | Missing | Retry with a different model |
| E5 | Delete entry / delete all | `delete_history_entry` | — | Same + delete all | M5 | Missing | — |
| E6 | History limit + retention period | `S.history_limit`, `S.recording_retention_period` | — | Same | M5 | Missing | — |
| E7 | Copy last transcript (tray) | `H/src-tauri/src/tray.rs:505` | — | Menu item | M5 | Missing | — |
| E8 | Open recordings folder | `open_recordings_folder` | — | Same | M5 | Missing | — |
| E9 | Disable history | `S.history_limit` = 0 | — | Explicit toggle | M5 | Missing | — |

## F. App shell

| # | Feature | Handy source | How Handy does it | Utter plan | M | Status | Can we do better? |
|---|---|---|---|---|---|---|---|
| F1 | Tray icon with idle / recording / transcribing states | `H/src-tauri/src/tray.rs`, `resources/*.png` | PNG icons | Own SF Symbol-style template icons | M1 | Missing | — |
| F2 | Tray menu: model switcher, unload, cancel, settings, check updates, copy last, quit | `H/src-tauri/src/tray.rs:471-552` | — | Menu per GOAL G5 (+ mode, microphone, history, shortcut) | M1/M5 | Missing | — |
| F3 | Show / hide tray icon | `S.show_tray_icon` | — | Same (app reachable by relaunch) | M5 | Missing | — |
| F4 | Start hidden | `S.start_hidden` | — | Menu-bar app never opens a window on launch unless onboarding | M5 | Missing | — |
| F5 | Launch at login | `S.autostart_enabled` | tauri-plugin-autostart | `SMAppService.mainApp` | M5 | Missing | — |
| F6 | Recording overlay, position top/bottom/none | `S.overlay_position`, `H/src-tauri/src/overlay.rs` | webview NSPanel | Native non-activating NSPanel | M4 | Missing | **Better**: native, measure time-to-visible |
| F7 | Overlay style none / minimal / live | `S.overlay_style` | — | Same | M4 | Missing | — |
| F8 | Level meter in overlay | `emit_levels` in `overlay.rs:730` | web canvas | Core Animation bars | M4 | Missing | — |
| F9 | Theme light / dark / system | `S.theme` | CSS | Follows system (native); explicit override | M5 | Missing | — |
| F10 | UI localisation (27 locales) and app-language picker | `H/src/i18n/locales/`, `S.app_language` | i18next | English at 1.0 using `String(localized:)` so locales can be added; other locales **N/A for 1.0** | M5 | Missing | — |
| F11 | Onboarding (mic + accessibility permissions) | `H/src/components/onboarding/` | — | Native onboarding with deep links + live re-check | M4 | Missing | — |
| F12 | Update checks + "What's new" | `S.update_checks_enabled`, `S.show_whats_new_on_update` | tauri-plugin-updater | Sparkle 2 (release notes shown by Sparkle) | M7 | Missing | — |
| F13 | Debug mode (⌘⇧D), log level, keyboard diagnostic | `S.debug_mode`, `S.log_level`, `secure_input.rs` diagnostic | — | Debug pane: log level, open logs, latency breakdown of last dictation | M5 | Missing | Per-stage latency view |
| F14 | CLI remote control: `--toggle-transcription`, `--toggle-post-process`, `--cancel`, `--start-hidden`, `--no-tray`, `--debug` | README "CLI Parameters" | single-instance plugin | Same flags forwarded to running instance via `NSDistributedNotificationCenter`; also `utter://` URL scheme | M5 | Missing | URL scheme for Shortcuts/Raycast |
| F15 | Single instance | tauri-plugin-single-instance | — | `NSRunningApplication` check | M5 | Missing | — |
| F16 | Open app-data / log directory | `open_app_data_dir`, `open_log_dir` | — | Settings → Privacy / Debug buttons | M5 | Missing | — |
| F17 | Clear local data | — | — | Settings → Privacy | M5 | Missing | — |
| F23 | Update checks locked by admin/managed config | `is_update_checks_locked` in `H/src-tauri/src/commands/mod.rs:27` | managed setting disables the toggle | Honour a managed `UpdateChecksDisabled` default (`defaults write` / MDM profile) | M7 | Missing | — |
| F18 | Homebrew cask | README | community cask | Cask draft in repo | M7 | Missing | — |
| F19 | Portable mode | `H/src-tauri/src/portable.rs` | Windows only | — | — | N/A | Windows only |
| F20 | Keyboard implementation choice (Tauri vs handy-keys) | `S.keyboard_implementation` | two backends | One native backend with Carbon fallback | — | N/A | Implementation detail, no user-facing need |
| F21 | Experimental toggle / lazy stream close | `S.experimental_enabled`, `S.lazy_stream_close` | — | Covered by always-on mic (A11) | M4 | Missing | — |
| F22 | Windows / Linux builds | — | Tauri | — | — | N/A | Utter is Mac-only by design |

## G. G8 check: what Handy already has (recorded in M0)

| Utter differentiator from GOAL G8 | Does Handy have it? | Evidence |
|---|---|---|
| Personal vocabulary correction | **Yes** (custom words, fuzzy, threshold) | `H/src-tauri/src/audio_toolkit/text.rs:151` |
| Clean mode | **Partly**: filler-word removal toggle | `S.filler_word_removal_enabled` |
| Professional / Custom modes | **Partly**: LLM post-processing with a prompt library | `S.post_process_prompts` |
| Code mode | **No** | no code-specific processing in `audio_toolkit/text.rs` |
| AX insertion | **No** | `grep -rn AXUIElement src-tauri/src` → 0 hits |
| Per-app insertion table | **No** | single global `S.paste_method` |
| Full clipboard restore (all types) | **No** (text, or image only if no text) | `H/src-tauri/src/clipboard.rs:63-106` |
| Searchable history | **No** search command | `H/src-tauri/src/commands/history.rs` (get/delete/save/retry only) |
| Native (non-web) UI | **No** (Tauri webview) | `H/src-tauri/Cargo.toml` |
