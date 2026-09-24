#!/usr/bin/env bash
# Runs the inference probe over the fixtures for every installed model and
# writes bench/results/<date>.json. Fails (and writes nothing) if any model
# fails. (M6 replaces the probe with utter-bench, which adds app launch,
# key-down→capture, insert latency, RSS and CPU.)
set -euo pipefail
cd "$(dirname "$0")/.."
probe=core/target/release/examples/runtime_probe
models_dir="${UTTER_MODELS_DIR:-$HOME/Library/Application Support/Utter/Models}"
mkdir -p bench/results
out="bench/results/$(date +%F).json"
log="bench/results/$(date +%F).log"

shopt -s nullglob
models=("$models_dir"/*/*.gguf)
if (( ${#models[@]} == 0 )); then
  echo "No models found in $models_dir. Run 'make models' first." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$log"
failed=0
for m in "${models[@]}"; do
  id="$(basename "$(dirname "$m")")"
  if ! "$probe" --json "$m" fixtures/audio/*.wav > "$tmp/$id.jsonl" 2>> "$log"; then
    echo "Benchmark failed for model $id (see $log)." >&2
    failed=1
  fi
done
(( failed == 0 )) || exit 1

runs=$(cat "$tmp"/*.jsonl | grep -c '^{' || true)
if (( runs == 0 )); then
  echo "Benchmark produced no results (see $log)." >&2
  exit 1
fi

{
  printf '{"date":"%s","git":"%s","runtime":"%s","machine":{"cpu":"%s","memory_bytes":%s,"macos":"%s"},"runs":[' \
    "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD)" "transcribe-cpp 0.2.3" \
    "$(sysctl -n machdep.cpu.brand_string)" "$(sysctl -n hw.memsize)" "$(sw_vers -productVersion)"
  first=1
  for f in "$tmp"/*.jsonl; do
    while IFS= read -r line; do
      [[ $line == \{* ]] || continue
      (( first )) || printf ','
      first=0
      printf '%s' "$line"
    done < "$f"
  done
  printf ']}\n'
} > "$out"
echo "Wrote $out ($runs rows)"
