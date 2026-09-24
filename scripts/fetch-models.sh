#!/usr/bin/env bash
# Downloads the models the test suite and bench use, from pinned Hugging Face
# revisions, and verifies SHA-256. Idempotent; resumes partial downloads.
# (The in-app model manager arrives in M3; this is developer tooling.)
set -euo pipefail
dir="${UTTER_MODELS_DIR:-$HOME/Library/Application Support/Utter/Models}"

# id | repo | revision | file | sha256
models=(
  "parakeet-tdt-0.6b-v3|handy-computer/parakeet-tdt-0.6b-v3-gguf|85ac09ea12fc4b1112fa76810059364bc6adc9de|parakeet-tdt-0.6b-v3-Q8_0.gguf|5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7"
  "whisper-small|handy-computer/whisper-small-gguf|c0214bd34be9296695486f838e0142f900803159|whisper-small-Q8_0.gguf|9b9c8811bbcc82a7766f0fb0925614bdacb0923b2cc630daeac17108b655b860"
)

for entry in "${models[@]}"; do
  IFS='|' read -r id repo rev file sha <<< "$entry"
  dest="$dir/$id/$file"
  mkdir -p "$dir/$id"
  if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$sha" ]]; then
    echo "ok       $id"
    continue
  fi
  echo "download $id"
  curl -fL --retry 3 -C - -o "$dest.partial" "https://huggingface.co/$repo/resolve/$rev/$file"
  got="$(shasum -a 256 "$dest.partial" | cut -d' ' -f1)"
  if [[ "$got" != "$sha" ]]; then
    echo "Checksum mismatch for $id (got $got). Deleting the partial file; run again." >&2
    rm -f "$dest.partial"
    exit 1
  fi
  mv "$dest.partial" "$dest"
  echo "verified $id"
done
