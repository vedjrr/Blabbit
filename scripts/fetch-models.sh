#!/usr/bin/env bash
# Downloads the models the test suite and bench use, from pinned Hugging Face
# revisions, and verifies SHA-256. Idempotent; resumes partial downloads.
# Developer tooling (the app has its own Model Manager). Covers every model
# `make test` loads: Parakeet V3 / Whisper Small (fixtures), Whisper Large v3
# Turbo + Moonshine (switch test), Moonshine (Model Manager download tests),
# Whisper Medium (incremental transcription on a padded-window model).
set -euo pipefail
dir="${SAYLESS_MODELS_DIR:-$HOME/Library/Application Support/SayLess/Models}"

# id | repo | revision | file | sha256
models=(
  "parakeet-tdt-0.6b-v3|handy-computer/parakeet-tdt-0.6b-v3-gguf|85ac09ea12fc4b1112fa76810059364bc6adc9de|parakeet-tdt-0.6b-v3-Q8_0.gguf|5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7"
  "whisper-small|handy-computer/whisper-small-gguf|c0214bd34be9296695486f838e0142f900803159|whisper-small-Q8_0.gguf|9b9c8811bbcc82a7766f0fb0925614bdacb0923b2cc630daeac17108b655b860"
  "whisper-large-v3-turbo|handy-computer/whisper-large-v3-turbo-gguf|5eaf945c7978e564bae5b28a5b1639dd93c2bfb1|whisper-large-v3-turbo-Q8_0.gguf|b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183"
  "moonshine-base|handy-computer/moonshine-base-gguf|3ef112378a8cf46ac8b278d9bfa2d15c846704b8|moonshine-base-Q8_0.gguf|7f0027dfd857d310b63a85ef57cadf183da712cc374f85a648f8bc18aaa2efc8"
  "whisper-medium|handy-computer/whisper-medium-gguf|ec78f06fded51aa82cde751678b78f76f78c8b7f|whisper-medium-Q8_0.gguf|09e6a65e7de377aa5b10bae24608bc6f8ca2ed04b3993ef10d4a02bcd9a82adf"
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
