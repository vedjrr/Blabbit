#!/usr/bin/env bash
# Removes Say Less and everything it stored on this Mac. Asks before deleting.
set -euo pipefail
cache_dir="$(getconf DARWIN_USER_CACHE_DIR)dev.sayless.mac"
paths=(
  "/Applications/SayLess.app"
  "$HOME/Library/Application Support/SayLess"   # models (up to several GB) and history
  "$HOME/Library/Logs/SayLess"
  "$HOME/Library/Caches/dev.sayless.mac"
  "$HOME/Library/HTTPStorages/dev.sayless.mac"   # URLSession storage (model downloads, update checks)
  "$cache_dir"                                 # compiled Metal shaders
)
echo "This removes Say Less, its models, history, logs, caches and settings:"
for p in "${paths[@]}"; do [[ -e "$p" ]] && echo "  $p"; done
echo "  settings (defaults domain dev.sayless.mac) and the Anthropic key in the Keychain, if saved"
# No terminal to answer (piped, or EOF): treat as No.
read -r -p "Continue? [y/N] " answer || answer=""
[[ "$answer" == [yY]* ]] || { echo "Nothing removed."; exit 0; }
# Quit it and wait, so it can't write settings or a log line after they're deleted.
osascript -e 'tell application id "dev.sayless.mac" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x SayLess >/dev/null || break; sleep 0.5; done
if pgrep -x SayLess >/dev/null; then pkill -x SayLess || true; sleep 1; fi
# Launch at Login: unregister while the app still exists.
osascript -e 'tell application "System Events" to delete (every login item whose name is "Say Less")' >/dev/null 2>&1 || true
for p in "${paths[@]}"; do rm -rf "$p"; done
defaults delete dev.sayless.mac 2>/dev/null || true
security delete-generic-password -s dev.sayless.mac.processing -a anthropic-api-key >/dev/null 2>&1 || true
echo "Removed. To also clear its permissions: tccutil reset All dev.sayless.mac"
echo "If Say Less still shows under System Settings → General → Login Items, remove it there."
