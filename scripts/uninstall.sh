#!/usr/bin/env bash
# Removes Utter and everything it stored on this Mac. Asks before deleting.
set -euo pipefail
cache_dir="$(getconf DARWIN_USER_CACHE_DIR)dev.utter.mac"
paths=(
  "/Applications/Utter.app"
  "$HOME/Library/Application Support/Utter"   # models (up to several GB) and history
  "$HOME/Library/Logs/Utter"
  "$HOME/Library/Caches/dev.utter.mac"
  "$cache_dir"                                 # compiled Metal shaders
)
echo "This removes Utter, its models, history, logs, caches and settings:"
for p in "${paths[@]}"; do [[ -e "$p" ]] && echo "  $p"; done
echo "  settings (defaults domain dev.utter.mac) and the Anthropic key in the Keychain, if saved"
read -r -p "Continue? [y/N] " answer
[[ "$answer" == [yY]* ]] || { echo "Nothing removed."; exit 0; }
osascript -e 'tell application id "dev.utter.mac" to quit' 2>/dev/null || true
for p in "${paths[@]}"; do rm -rf "$p"; done
defaults delete dev.utter.mac 2>/dev/null || true
security delete-generic-password -s dev.utter.mac.processing -a anthropic-api-key >/dev/null 2>&1 || true
echo "Removed. To also clear its permissions: tccutil reset All dev.utter.mac"
