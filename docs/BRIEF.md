You are Claude Opus 5.5 acting as a senior macOS engineer, Rust engineer, ML inference engineer, and product engineer.

I want you to build a complete, production-quality macOS local-first dictation application inspired by the open-source project Handy.

The goal is to achieve feature parity, workflow parity, model support, and comparable responsiveness to Handy, while creating an independently implemented product with its own name, branding, UI details, and code.

Do not build a demo or mockup. Build the actual working application.

⸻

1. FIRST: STUDY HANDY

Before writing substantial code, inspect Handy’s current public source code and documentation:

GitHub:
https://github.com/cjpais/Handy

Website/docs:
https://handy.computer/

Study the repository carefully, especially:

* Architecture
* Rust/backend implementation
* macOS integration
* Audio capture
* Global hotkeys
* Accessibility/text insertion
* Model management
* Model downloading
* Model loading
* Local inference
* Supported models
* Parakeet
* Whisper
* SenseVoice
* Moonshine
* Model quantization
* Apple Silicon optimization
* Recording/transcription lifecycle
* Settings
* Menu bar behavior
* Overlay
* Error handling
* Privacy/offline behavior
* Performance optimizations

Use Handy as the primary technical reference when making architectural decisions.

Do not blindly copy its source code, branding, assets, icons, or UI.

Implement the functionality independently using appropriate open-source libraries and public documentation.

The target is:

Handy-level functionality + Handy-level local model support + Handy-level responsiveness + our own implementation and identity.

⸻

2. CORE EXPERIENCE

The application is a system-wide macOS dictation utility.

The primary workflow must be:

Hold global hotkey
→ microphone starts immediately
→ minimal floating recording indicator appears
→ user speaks
→ release hotkey
→ local model transcribes
→ optional text processing
→ text is inserted at the current cursor
→ overlay disappears

It must work in applications including:

* Safari
* Chrome
* Arc
* VS Code
* Cursor
* Xcode
* Terminal
* iTerm
* Slack
* Discord
* WhatsApp
* Messages
* Mail
* Notes
* Notion
* ChatGPT
* normal macOS text fields

The user should never need to manually copy/paste the transcription.

⸻

3. PERFORMANCE

Performance is one of the most important requirements.

The application must feel as fast and responsive as Handy.

Do NOT initialize the speech model every time the user speaks.

Instead:

App launch
→ selected model loads
→ model warms up
→ model stays ready in memory
→ hotkey starts recording immediately
→ release triggers inference immediately
→ text is inserted immediately

Optimize for Apple Silicon.

Use appropriate:

* Metal/GPU acceleration
* CPU optimizations
* quantized models
* efficient audio processing
* background model loading
* model warm-up
* asynchronous processing
* memory management
* streaming/chunked inference where useful

Measure startup, model loading, transcription and insertion latency rather than assuming performance.

⸻

4. MODEL SYSTEM

This is a major part of the application.

Build a proper model manager similar in concept to Handy’s.

Models must be downloaded separately rather than bundled into the main application.

The user should be able to:

* browse available models
* download
* pause/cancel
* retry failed downloads
* verify downloads
* delete models
* switch models
* see model size
* see supported languages
* see installed/downloaded status
* select a default model

Initially investigate and support models in the same class as Handy, including where technically and legally possible:

* Parakeet V3
* Parakeet V2
* Whisper variants
* Whisper Small
* Whisper Medium
* Whisper Large/V3
* Whisper Turbo variants
* SenseVoice
* Moonshine

Do not claim support for a model until you have verified that it actually works.

Use a modular interface such as:

SpeechModel

* load()
* unload()
* transcribe()
* metadata()
* supportedLanguages()
* memoryRequirements()

Then implement model adapters.

Use mature inference runtimes rather than implementing neural-network inference yourself.

Investigate the runtimes used by Handy and appropriate alternatives such as:

* transcribe-rs
* transcribe-cpp
* whisper.cpp
* ONNX Runtime
* Core ML
* other suitable Apple Silicon-compatible runtimes

Choose based on actual model compatibility, performance and licensing.

⸻

5. LOCAL-FIRST / PRIVACY

Basic dictation must work completely offline after the model is downloaded.

Normal speech recognition must follow:

Microphone
→ local inference
→ local text

Do not upload audio or transcription by default.

No Python, Docker, Node.js or external server should be required at runtime.

Internet should only be required for things such as:

* model downloads
* application updates
* explicitly enabled optional cloud features

Clearly handle microphone and Accessibility permissions.

⸻

6. AUDIO

Implement a reliable native macOS audio pipeline using AVFoundation/AVAudioEngine or an appropriate equivalent.

Handle:

* microphone permission
* input device selection
* Bluetooth microphones
* sample-rate conversion
* mono conversion
* PCM buffering
* low-latency capture
* microphone disconnection
* audio interruptions
* silence
* short recordings
* long recordings

Recording must only happen after intentional user activation.

⸻

7. GLOBAL HOTKEY

Implement a true system-wide global hotkey.

Default behavior should be push-to-talk:

Hold shortcut
→ recording

Release
→ transcription

Allow users to configure the shortcut.

Also support toggle mode if practical.

Handle conflicts and ensure the shortcut does not interfere with normal typing.

⸻

8. TEXT INSERTION

This needs to be extremely reliable.

After transcription, automatically insert text into the currently focused application.

Use appropriate macOS Accessibility APIs and clipboard/CGEvent fallback strategies.

Suggested fallback:

1. Accessibility insertion
2. Clipboard-based insertion
3. Other appropriate macOS insertion mechanism

Preserve the user’s existing clipboard contents whenever possible.

Handle:

* browsers
* Electron apps
* terminal applications
* code editors
* normal text fields
* applications without Accessibility support
* protected/secure fields

⸻

9. RECORDING UI

Create a minimal native macOS floating overlay.

It should:

* appear instantly
* not steal focus
* stay above normal windows
* show recording state
* show microphone activity
* show recording duration
* show processing state
* disappear immediately after completion

Keep it extremely lightweight.

The application should primarily live in the menu bar.

⸻

10. MENU BAR + SETTINGS

Provide a polished macOS menu bar application.

Menu should include:

* Start/Stop Dictation
* Current model
* Current mode
* Microphone
* Settings
* Model Manager
* History
* Keyboard Shortcut
* Quit

Settings should cover:

General

* Launch at login
* Appearance
* Menu bar behavior
* Startup behavior
* Updates

Dictation

* Push-to-talk/toggle
* Global hotkey
* Auto punctuation
* Capitalization
* Paragraph detection
* Filler-word removal

Models

* Installed models
* Available models
* Default model
* Model storage

Audio

* Input device
* Microphone settings

Text Insertion

* Accessibility insertion
* Clipboard fallback
* Clipboard preservation
* Newline behavior

Language

* Auto-detect
* Preferred language

Privacy

* Local-only mode
* History
* Audio retention
* Clear local data

⸻

11. TRANSCRIPTION MODES

Implement:

Exact

Closest possible transcription.

Clean

Remove filler words and obvious verbal noise while preserving meaning.

Professional

Improve grammar and readability without changing meaning.

Code

Preserve technical terminology and developer language.

Custom

Allow the user to define their own processing instruction.

Keep transcription and post-processing separate:

Raw Transcript
→ Processing Pipeline
→ Final Text

Basic dictation must not depend on an LLM.

⸻

12. PERSONAL VOCABULARY

Add a local custom vocabulary system.

Users can add words and phrases such as:

HoldMyCode
Decivra
Maynooth
PostgreSQL
TypeScript
SwiftUI
WhisperKit

Use these terms during the correction/post-processing pipeline where appropriate.

⸻

13. OPTIONAL AI PROCESSING

Keep AI post-processing modular and optional.

Create an abstraction such as:

TextProcessor
├── Local
├── OpenAI
├── Anthropic
├── Ollama
└── Custom

Only implement providers that are practical for the first version.

The application must remain fully functional without cloud AI.

⸻

14. HISTORY

Provide optional local transcription history.

Store:

* timestamp
* duration
* model
* raw transcription
* final text

Allow:

* search
* copy
* delete
* delete all
* disable history

Privacy mode should allow history to be completely disabled.

⸻

15. ARCHITECTURE

Prefer a native macOS frontend with a high-performance core.

Recommended direction:

macOS layer

* Swift
* SwiftUI
* AppKit where necessary
* AVFoundation
* Accessibility APIs
* native macOS APIs

Core/inference

* Rust where appropriate
* modular speech inference layer
* model management layer
* audio processing layer

Conceptually:

SwiftUI / AppKit
↓
Application Coordinator
↓
┌───────┼────────┐
Hotkey  Audio   Settings
↓
Audio Pipeline
↓
Rust Core
↓
Model Runtime
↓
Parakeet / Whisper / etc.
↓
Raw Transcript
↓
Processing Pipeline
↓
Final Text
↓
Text Insertion
↓
Current Cursor

Keep every major component replaceable.

⸻

16. ERROR HANDLING

Handle real-world failures properly:

* microphone permission denied
* Accessibility permission denied
* model missing
* model download failure
* corrupted model
* insufficient memory
* unsupported model
* inference failure
* microphone disconnected
* hotkey conflict
* text insertion failure
* unavailable focused application

Give users clear messages instead of developer stack traces.

⸻

17. TESTING

Create actual tests for:

* audio capture
* model loading
* transcription
* model switching
* model downloads
* global hotkeys
* text insertion
* clipboard preservation
* settings
* permissions
* history
* error handling

Create a manual test checklist covering:

Safari
Chrome
VS Code
Cursor
Terminal
Slack
Discord
Messages
Notes
ChatGPT

⸻

18. PERFORMANCE BENCHMARKING

Add internal benchmarking for:

* application startup
* model loading
* model warm-up
* recording latency
* transcription latency
* insertion latency
* RAM usage
* CPU usage
* GPU usage

Test the available models on Apple Silicon.

Do not make unsupported performance claims.

⸻

19. DISTRIBUTION

Prepare the project for real-world distribution.

Include:

* proper macOS application bundle
* application icon
* signing configuration
* notarization instructions
* DMG generation
* update mechanism
* clean uninstall
* GitHub release instructions
* Homebrew Cask compatibility where practical

The final project should be something I can build, sign and distribute to real users.

⸻

20. DEVELOPMENT PROCESS

Do NOT immediately generate thousands of lines of code.

First inspect Handy and the relevant open-source dependencies.

Then:

1. Analyze the existing architecture.
2. Decide our architecture.
3. Verify model compatibility and licenses.
4. Set up the repository.
5. Implement the smallest working vertical slice.
6. Test it.
7. Expand feature-by-feature.
8. Benchmark it.
9. Polish the UX.
10. Prepare distribution.

The first working milestone must be:

Global hotkey
→ microphone
→ local Parakeet/Whisper transcription
→ automatic text insertion into TextEdit

Once this works reliably, expand the application.

Do not stop at planning or architecture documentation.

Actually build and test the application.

⸻

21. IMPORTANT RULES

Do not:

* create fake transcription
* mock model downloads
* use placeholder functionality
* require a separate server
* require Python at runtime
* require Docker
* require Node.js at runtime
* upload audio by default
* reload the model for every recording
* claim support for untested models
* create a superficial UI prototype instead of the actual product

Prioritize, in order:

1. Responsiveness
2. Reliable transcription
3. Local inference
4. Apple Silicon performance
5. Reliable text insertion
6. Native macOS UX
7. Privacy
8. Maintainable architecture

⸻

FINAL OBJECTIVE

Build an independently implemented macOS dictation application that provides the same overall class of experience as Handy:

instant push-to-talk dictation + local models + Parakeet/Whisper ecosystem + model manager + offline inference + system-wide text insertion + minimal overlay + menu bar app + configurable settings + privacy + Apple Silicon optimization.

Use Handy’s current public implementation as the primary technical reference throughout development.

Do not merely describe what should be built.

Build it. Test it. Benchmark it. Fix the problems you encounter. Then continue until the application is genuinely usable.