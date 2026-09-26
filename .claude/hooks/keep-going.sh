#!/usr/bin/env bash
# Stop hook: blocks Claude from stopping until PROGRESS.md says STATUS: DONE.
# Safety valves: MAX_ITERS cap, and a human "STOP" file to end the loop manually.
set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROGRESS="$ROOT/PROGRESS.md"
COUNTER="$ROOT/.claude/.loop-count"
MAX_ITERS="${BLABBIT_MAX_ITERS:-200}"

cat >/dev/null  # consume hook JSON on stdin

[[ -f "$ROOT/STOP" ]] && exit 0
[[ -f "$PROGRESS" ]] && head -n1 "$PROGRESS" | grep -q "STATUS: DONE" && exit 0

n=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNTER"
if (( n > MAX_ITERS )); then
  echo "Loop cap ($MAX_ITERS) reached. Summarise state in PROGRESS.md." >&2
  exit 0
fi

# If everything left is human-blocked, stop and let the human act.
if grep -q "STATUS: WAITING_ON_HUMAN" "$PROGRESS" 2>/dev/null; then
  exit 0
fi

reason="Loop iteration $n/$MAX_ITERS. GOAL not met (PROGRESS.md is not STATUS: DONE). \
Re-read PROGRESS.md, pick the next unchecked task in the current milestone, implement, run make test, \
record evidence, commit, update PROGRESS.md. If at a milestone gate, run the critic subagent first. \
If ONLY human-blocked work remains, set line 1 to STATUS: WAITING_ON_HUMAN and list the asks."

printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$reason" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
