---
description: Resume the autonomous build loop (use after a break, a crash, or WAITING_ON_HUMAN)
---
Resume the Blabbit build loop.

1. Read `CLAUDE.md`, `docs/GOAL.md`, `docs/MILESTONES.md`, `PROGRESS.md`. Run `git log --oneline -15` and `make test` to see real state; trust the repo over the notes if they disagree, and fix the notes.
2. If line 1 is `STATUS: WAITING_ON_HUMAN`, check whether I resolved the items under `## Blocked on human` ($ARGUMENTS may describe what I did). Verify each one, move resolved ones to Done with evidence, set line 1 back to `STATUS: IN_PROGRESS`.
3. Continue the working loop from the next unchecked task. Do not stop until `STATUS: DONE` or only human-blocked work remains.
