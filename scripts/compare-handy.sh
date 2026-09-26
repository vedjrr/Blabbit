#!/usr/bin/env bash
# G8: Say Less vs Handy side by side, measured the same way on this Mac.
# Usage: scripts/compare-handy.sh /path/to/Handy.app [/path/to/SayLess.app]
# Before running: in Handy, download Parakeet V3, select it, and set model
# unloading to "Never", so both apps idle with the same model resident.
# Both apps are quit first and after. Output: evidence/m7/handy_comparison.log
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d "${1:-}" ]] || { echo "usage: scripts/compare-handy.sh /path/to/Handy.app [/path/to/SayLess.app]" >&2; exit 2; }
handy="${1:?usage: scripts/compare-handy.sh /path/to/Handy.app [/path/to/SayLess.app]}"
sayless="${2:-build/SayLess.app}"
out=evidence/m7/handy_comparison.log
mkdir -p evidence/m7

exe() { /usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$1/Contents/Info.plist"; }
bundle_id() { /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist"; }
# ps "time" is [[H:]M]M:SS.cc; the last field holds seconds with hundredths.
cpu_seconds() { ps -o time= -p "$1" | tr -d ' ' | awk -F: '{ s=0; for (i=1; i<=NF; i++) s = s*60 + $i; printf "%.2f\n", s }'; }

# Resident KB of the app plus the helpers it started (Handy's web view runs in
# WebKit processes launched by the system, so they aren't its children): any
# WebKit process that started after launch counts (so keep other browsers and
# web-view apps closed during the run, or their new helpers would be counted).
total_rss() { # pid launch_epoch
  local main extra
  main=$(ps -o rss= -p "$1" | tr -d ' ')
  extra=$(ps -A -o pid=,lstart=,rss=,comm= | awk -v t0="$2" '
    /com\.apple\.WebKit\./ {
      cmd = "date -j -f \"%a %b %e %T %Y\" \"" $2 " " $3 " " $4 " " $5 " " $6 "\" +%s"
      cmd | getline started; close(cmd)
      if (started >= int(t0)) sum += $7
    } END { print sum + 0 }')
  echo $(( main + extra ))
}

# Both apps load a model lazily or at launch; one short dictation (start, then
# stop a second later) makes sure the model is resident in both before measuring.
# The microphone records about a second of room noise; nothing is typed.
trigger_model() { # app
  local bin="$1/Contents/MacOS/$(exe "$1")"
  "$bin" --toggle-transcription >/dev/null 2>&1 || true
  sleep 1
  "$bin" --toggle-transcription >/dev/null 2>&1 || true
}

measure() { # app → "launch_to_settled_ms settled_rss_mb idle_cpu_percent"
  local app=$1 name pid t0 now prev stable_since rss
  name=$(exe "$app")
  osascript -e "tell application id \"$(bundle_id "$app")\" to quit" >/dev/null 2>&1 || true
  sleep 2
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  open "$app"
  for _ in $(seq 1 100); do pid=$(pgrep -nx "$name" || true); [[ -n $pid ]] && break; sleep 0.1; done
  [[ -n ${pid:-} ]] || { echo "error: $name did not start" >&2; return 1; }
  sleep 2 # the app registers its single-instance listener
  trigger_model "$app"
  # Settled = resident size within ±2 % for 3 s (model loaded, UI idle); cap 60 s.
  prev=0; stable_since=""
  for _ in $(seq 1 240); do
    kill -0 "$pid" 2>/dev/null || { echo "error: $name quit while being measured" >&2; return 1; }
    rss=$(total_rss "$pid" "$t0")
    now=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    if (( prev > 0 )) && (( rss * 100 >= prev * 98 && rss * 100 <= prev * 102 )); then
      [[ -n $stable_since ]] || stable_since=$now
      if perl -e "exit(!($now - $stable_since >= 3))"; then break; fi
    else
      stable_since=""; prev=$rss
    fi
    sleep 0.25
  done
  local settled_ms; settled_ms=$(perl -e "printf '%.0f', (${stable_since:-$now} - $t0) * 1000")
  # Idle CPU: CPU time used over 10 s of doing nothing, as a percentage.
  local c0 c1; c0=$(cpu_seconds "$pid"); sleep 10; c1=$(cpu_seconds "$pid")
  local cpu; cpu=$(perl -e "printf '%.2f', ($c1 - $c0) / 10 * 100")
  echo "$settled_ms $(( $(total_rss "$pid" "$t0") / 1024 )) $cpu"
  osascript -e "tell application id \"$(bundle_id "$app")\" to quit" >/dev/null 2>&1 || kill "$pid"
}

{
  echo "# $(date -u +%FT%TZ) Say Less vs Handy on $(sysctl -n machdep.cpu.brand_string), $(sw_vers -productVersion)"
  echo "# Say Less: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$sayless/Contents/Info.plist") ($sayless)"
  echo "# Handy: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$handy/Contents/Info.plist") ($handy)"
  echo "app  run  launch_to_settled_ms  settled_rss_mb  idle_cpu_percent"
  echo "# launch_to_settled includes one triggered dictation (model resident in both); rss sums WebKit helpers started after launch"
  for run in 1 2 3; do
    u=$(measure "$sayless") || { echo "sayless $run failed"; continue; }
    echo "sayless $run $u"
    h=$(measure "$handy") || { echo "handy $run failed"; continue; }
    echo "handy $run $h"
  done
} | tee "$out"
