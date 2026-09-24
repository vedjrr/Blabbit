#!/usr/bin/env bash
# Runs the inference probe over the fixtures for every installed model and
# writes bench/results/<date>.json. (M6 replaces the probe with utter-bench,
# which adds app launch, key-down→capture, insert latency, RSS and CPU.)
set -euo pipefail
cd "$(dirname "$0")/.."
probe=core/target/release/examples/runtime_probe
models_dir="${UTTER_MODELS_DIR:-$HOME/Library/Application Support/Utter/Models}"
mkdir -p bench/results
out="bench/results/$(date +%F).json"

shopt -s nullglob
models=("$models_dir"/*/*.gguf)
if (( ${#models[@]} == 0 )); then
  echo "No models found in $models_dir. Run 'make models' first." >&2
  exit 1
fi

{
  printf '{"date":"%s","machine":{"cpu":"%s","memory_bytes":%s,"macos":"%s"},"runs":[' \
    "$(date -u +%FT%TZ)" "$(sysctl -n machdep.cpu.brand_string)" "$(sysctl -n hw.memsize)" "$(sw_vers -productVersion)"
  first=1
  for m in "${models[@]}"; do
    while IFS= read -r line; do
      [[ $line == \{* ]] || continue
      (( first )) || printf ','
      first=0
      printf '%s' "$line"
    done < <("$probe" --json "$m" fixtures/audio/*.wav 2>/dev/null)
  done
  printf ']}\n'
} > "$out"
echo "Wrote $out"
