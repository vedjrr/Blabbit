#!/usr/bin/env bash
# Removes Utter and everything it stored on this Mac. Asks before deleting.
set -euo pipefail
cache_dir="$(getconf DARWIN_USER_CACHE_DIR)dev.utter.mac"
paths=(
  "/Applications/Utter.app"
  "$HOME/Library/Application Support/Utter"   # models (up to several GB) and history
  "$HOME/Library/Logs/Utter"
  "$HOME/Library/Caches/dev.utter.mac"
  "$HOME/Library/HTTPStorages/dev.utter.mac"   # URLSession storage (model downloads, update checks)
  "$cache_dir"                                 # compiled Metal shaders
)
echo "This removes Utter, its models, history, logs, caches and settings:"
for p in "${paths[@]}"; do [[ -e "$p" ]] && echo "  $p"; done
echo "  settings (defaults domain dev.utter.mac) and the Anthropic key in the Keychain, if saved"
# No terminal to answer (piped, or EOF): treat as No.
read -r -p "Continue? [y/N] " answer || answer=""
[[ "$answer" == [yY]* ]] || { echo "Nothing removed."; exit 0; }
# Quit it and wait, so it can't write settings or a log line after they're deleted.
osascript -e 'tell application id "dev.utter.mac" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x Utter >/dev/null || break; sleep 0.5; done
if pgrep -x Utter >/dev/null; then pkill -x Utter || true; sleep 1; fi
# Launch at Login: unregister while the app still exists.
osascript -e 'tell application "System Events" to delete (every login item whose name is "Utter")' >/dev/null 2>&1 || true
for p in "${paths[@]}"; do rm -rf "$p"; done
defaults delete dev.utter.mac 2>/dev/null || true
security delete-generic-password -s dev.utter.mac.processing -a anthropic-api-key >/dev/null 2>&1 || true
echo "Removed. To also clear its permissions: tccutil reset All dev.utter.mac"
echo "If Utter still shows under System Settings → General → Login Items, remove it there."
