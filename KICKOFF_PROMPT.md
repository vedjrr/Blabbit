# Kickoff prompt — paste this as your first message in Claude Code

---

You are building **Say Less**, a native macOS local-first dictation app with full Handy feature parity and responsiveness, then better than Handy wherever a native Mac app can measurably win. You are working autonomously in a loop and will not stop until the goal is met.

Read these now, in order, and treat them as binding:
1. `CLAUDE.md` — rules and working loop
2. `docs/GOAL.md` — definition of done (checkable, evidence required)
3. `docs/MILESTONES.md` — ordered milestones with gates
4. `docs/BRIEF.md` — the full product brief (requirements detail)
5. `PROGRESS.md` — current loop state

A Stop hook will send you back to work every time you try to finish, until line 1 of `PROGRESS.md` reads `STATUS: DONE`. Use that honestly: never set DONE unless every GOAL item has recorded evidence, and never weaken GOAL.md to get there.

How to work:
- Start at M0. Clone https://github.com/cjpais/Handy as a read-only reference, map how it does audio, hotkeys, insertion, model management and inference, then record decisions as ADRs in `docs/ARCHITECTURE.md`. Handy is the reference, not a source to copy: own code, name, UI and icon.
- Get to the M1 vertical slice (hotkey → mic → local Parakeet/Whisper → text in TextEdit) as fast as possible. Everything else is expansion of a working core.
- Each iteration: one small task → build → `make test` → verify against GOAL → record evidence → commit → update `PROGRESS.md`.
- At each milestone gate, invoke the `critic` subagent and fix every BLOCKER before moving on.
- Measure, don't assume. Every latency or model-support claim needs a command and its output in `PROGRESS.md`.
- When something only I can do comes up (Accessibility/Mic permission grants, speaking into the mic, signing with my Developer ID), add it to `## Blocked on human` with exact steps, then keep going on unblocked work. If only human-blocked work remains, set line 1 to `STATUS: WAITING_ON_HUMAN` and stop.
- If an approach fails 3 times, change approach and log why.

Machine: Apple Silicon Mac, latest macOS, Xcode and Rust installed (verify versions first and note them).

Begin with M0 now.
