# CLAUDE.md — Say Less (local-first macOS dictation)

Always-loaded project rules. Read this, then `PROGRESS.md`, at the start of every session.

## What we are building
A native macOS menu-bar dictation app with Handy-class behaviour: hold a hotkey, speak, release, and local text appears at the cursor in any app. Fully offline after model download. Working name **Say Less** (rename freely; never use Handy's name, icon, or assets).

Reference implementation: Handy — https://github.com/cjpais/Handy (note: the repo is `cjpais/Handy`, not `jaccas/handy`). Handy is MIT-licensed. Study its design; write our own code. Handy is Tauri (Rust + web UI); we are Swift/AppKit + Rust core, so its Rust inference layer is the most transferable part.

**Ambition:** full feature parity with Handy (tracked row by row in `docs/PARITY.md`), then beat it where a native Mac app can: speed, memory, insertion reliability and native UX. Every "better" claim must be measured.

## Source of truth
- `docs/GOAL.md` — definition of done. Nothing is "done" unless its check passes.
- `docs/MILESTONES.md` — ordered milestones with exit gates.
- `docs/ARCHITECTURE.md` — you write this in M0; it records decisions (ADRs).
- `PROGRESS.md` — loop state. You own it. Update it before every stop.

## Hard rules
1. No fake transcription, mocked downloads, placeholder UI, or stubbed success paths in shipped code. Test doubles live only under test targets.
2. Never claim a model, app, or latency number works unless you ran it and recorded the evidence (command + output or log path) in `PROGRESS.md`.
3. Model loads once, warms up, stays resident. Never load per recording.
4. No Python, Node, Docker, or servers at runtime. Build-time tooling is fine.
5. No network calls in the dictation path. Network only for model downloads, updates, and opt-in cloud processors.
6. One milestone at a time. Do not start milestone N+1 until N's exit gate passes.
7. Small, reviewable commits: `git commit` after each green step, message `M<n>: <what>`.
8. If blocked on something only the human can do (signing identity, granting TCC permissions, physical mic test), write it under `## Blocked on human` in `PROGRESS.md`, then continue with any unblocked work. Never spin retrying the same failing action more than 3 times — change approach or log the blocker.
9. Do not edit `docs/GOAL.md` acceptance criteria to make them pass. You may propose changes under `## Proposed goal changes`.

## Working loop (every iteration)
1. Read `PROGRESS.md` → pick the single next unchecked task in the current milestone.
2. Implement the smallest change that moves it forward.
3. Build + run tests (`make test`). Fix until green.
4. Verify against the relevant `GOAL.md` check. Record evidence.
5. At milestone gates, run the `critic` subagent (`.claude/agents/critic.md`) and fix everything it marks BLOCKER.
6. Update `PROGRESS.md`, commit, continue.

## Commands (create these in M0, keep them working)
- `make build` — build Rust core + Xcode app (Release, arm64)
- `make test` — Rust `cargo test` + `xcodebuild test`
- `make bench` — run `sayless-bench` and write `bench/results/<date>.json`
- `make dmg` — signed, notarised DMG (needs human creds)

## Style
Swift: SwiftUI for settings/model manager/history, AppKit for NSPanel overlay, status item, event taps. Swift concurrency; no main-thread blocking. Rust: `thiserror` errors, no `unwrap()` outside tests, exposed via UniFFI. Comments only where the why isn't obvious. User-facing errors in plain English, never stack traces.
