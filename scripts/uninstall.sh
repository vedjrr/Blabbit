#!/usr/bin/env bash
# Removes Blabbit and everything it stored on this Mac. Asks before deleting.
set -euo pipefail
cache_dir="$(getconf DARWIN_USER_CACHE_DIR)dev.blabbit.mac"
paths=(
  "/Applications/Blabbit.app"
  "$HOME/Library/Application Support/Blabbit"   # models (up to several GB) and history
  "$HOME/Library/Logs/Blabbit"
  "$HOME/Library/Caches/dev.blabbit.mac"
  "$HOME/Library/HTTPStorages/dev.blabbit.mac"   # URLSession storage (model downloads, update checks)
  "$cache_dir"                                 # compiled Metal shaders
)
echo "This removes Blabbit, its models, history, logs, caches and settings:"
for p in "${paths[@]}"; do [[ -e "$p" ]] && echo "  $p"; done
echo "  settings (defaults domain dev.blabbit.mac) and the Anthropic key in the Keychain, if saved"
# No terminal to answer (piped, or EOF): treat as No.
read -r -p "Continue? [y/N] " answer || answer=""
[[ "$answer" == [yY]* ]] || { echo "Nothing removed."; exit 0; }
# Quit it and wait, so it can't write settings or a log line after they're deleted.
osascript -e 'tell application id "dev.blabbit.mac" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x Blabbit >/dev/null || break; sleep 0.5; done
if pgrep -x Blabbit >/dev/null; then pkill -x Blabbit || true; sleep 1; fi
# Launch at Login: unregister while the app still exists.
osascript -e 'tell application "System Events" to delete (every login item whose name is "Blabbit")' >/dev/null 2>&1 || true
for p in "${paths[@]}"; do rm -rf "$p"; done
defaults delete dev.blabbit.mac 2>/dev/null || true
security delete-generic-password -s dev.blabbit.mac.processing -a anthropic-api-key >/dev/null 2>&1 || true
echo "Removed. To also clear its permissions: tccutil reset All dev.blabbit.mac"
echo "If Blabbit still shows under System Settings → General → Login Items, remove it there."
