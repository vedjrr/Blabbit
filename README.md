# Utter build kit — how to use

1. Make an empty repo, copy everything in this folder into it (including the hidden `.claude/`), `git init && git add -A && git commit -m "kit"`.
2. Add 3–5 short WAV fixtures to `fixtures/audio/` (16 kHz mono) with matching `.txt` reference transcripts. Record your own voice, including your vocabulary words.
3. `chmod +x .claude/hooks/keep-going.sh`, open Claude Code in the repo, pick Opus 5.5, paste `KICKOFF_PROMPT.md`.
4. The Stop hook keeps it working until `PROGRESS.md` line 1 is `STATUS: DONE`. It pauses on `STATUS: WAITING_ON_HUMAN` — do the listed asks, then run `/loop <what you did>`.
5. Emergency stop: `touch STOP` in the repo root. Cap: 200 iterations (`UTTER_MAX_ITERS`).

Files: `CLAUDE.md` (rules), `docs/GOAL.md` (done = checkable), `docs/MILESTONES.md` (order + gates), `docs/BRIEF.md` (your original spec), `PROGRESS.md` (loop state), `.claude/agents/critic.md` (independent reviewer), `.claude/hooks/keep-going.sh` (the loop).
# Utter
