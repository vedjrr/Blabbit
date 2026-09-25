#!/usr/bin/env bash
# Generates synthetic-speech fixtures with macOS `say` so tests have real audio
# before the human records their own voice (preferred; see PROGRESS.md).
# Output: fixtures/audio/tts_NN.wav (16 kHz mono s16le) + tts_NN.txt reference.
set -euo pipefail
cd "$(dirname "$0")/.."
out=fixtures/audio
mkdir -p "$out"

make_clip() {
  local id=$1 voice=$2 text=$3
  local aiff; aiff=$(mktemp -t utterfx).aiff
  say -v "$voice" -o "$aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$out/$id.wav"
  rm -f "$aiff"
  printf '%s\n' "$text" > "$out/$id.txt"
}

make_clip tts_01 "Samantha" "Testing Utter, one two three. HoldMyCode uses PostgreSQL."
make_clip tts_02 "Daniel" "The quick brown fox jumps over the lazy dog while the band plays in the park."
make_clip tts_03 "Karen" "Please schedule a meeting with the design team for next Tuesday afternoon at three."
make_clip tts_04 "Moira (English (Ireland))" "I studied computer science at Maynooth before moving into product engineering."
make_clip tts_05 "Reed (English (US))" "We rewrote the settings screen in SwiftUI and moved the backend to TypeScript."
make_clip tts_06 "Samantha" "Decivra transcribes speech with WhisperKit on the device."
