#!/usr/bin/env bash
# GitHub release without the Apple Developer Program (docs/RELEASING.md):
# the app `make build` signed (inside-out, hardened runtime) → DMG → EdDSA-signed
# Sparkle appcast. Not notarised, so people open it once with "Open Anyway";
# Sparkle installs later updates without that step.
#
# Signing identity: BLABBIT_SIGN_IDENTITY, else the Mac's "Apple Development"
# certificate (what `make build` uses). A real certificate keeps the app's code
# requirement stable between versions, so macOS keeps the Accessibility and
# Microphone permissions across updates; an ad-hoc signature would lose them
# at every update, so it is refused unless BLABBIT_ALLOW_ADHOC=1.
set -euo pipefail
cd "$(dirname "$0")/.."
app=build/Blabbit.app
ver=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' app/Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' app/Resources/Info.plist)
updates=build/updates
dmg="$updates/Blabbit-$ver.dmg"
sparkle_bin=app/.build/artifacts/sparkle/Sparkle/bin

[[ -d "$app" ]] || { echo "Build the app first (make build)." >&2; exit 2; }
if ! "$sparkle_bin/generate_keys" --account dev.blabbit.mac -p >/dev/null 2>&1; then
  echo "Cannot sign the update feed: no Sparkle key for account dev.blabbit.mac in the keychain (see docs/RELEASING.md)." >&2
  exit 2
fi

codesign --verify --strict --deep --verbose=1 "$app"
authority=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [[ -z "$authority" && "${BLABBIT_ALLOW_ADHOC:-0}" != 1 ]]; then
  echo "The app is ad-hoc signed: every update would reset people's Accessibility and Microphone permissions." >&2
  echo "Sign with a certificate (set BLABBIT_SIGN_IDENTITY and run make build), or set BLABBIT_ALLOW_ADHOC=1." >&2
  exit 2
fi
echo "Signed by: ${authority:-ad-hoc}"
# Nothing outside the bundle and the OS may be linked (Homebrew, Command Line Tools).
if otool -L "$app/Contents/MacOS/Blabbit" | tail -n +2 | grep -vE '^\s+(/System/|/usr/lib/|@rpath/Sparkle|@executable_path)'; then
  echo "The app links a library that won't exist on other Macs (above)." >&2
  exit 1
fi

mkdir -p "$updates"
rm -f "$dmg"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Blabbit.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "Blabbit $ver" -srcfolder "$staging" -ov -format UDZO "$dmg"
if [[ -n "$authority" ]]; then
  codesign --force --sign "${BLABBIT_SIGN_IDENTITY:-$authority}" "$dmg"
fi
hdiutil verify -quiet "$dmg"

# Every DMG in build/updates goes into the feed with an EdDSA signature made with
# the keychain key; installed copies check it against SUPublicEDKey.
"$sparkle_bin/generate_appcast" --account dev.blabbit.mac \
  --download-url-prefix "https://github.com/vedjrr/Blabbit/releases/download/v$ver/" "$updates"

# The website links to releases/latest/download/Blabbit.dmg, which needs a stable
# name; it lives outside build/updates so the appcast doesn't list it twice.
mkdir -p build/release
cp "$dmg" build/release/Blabbit.dmg
sum=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
echo
echo "Release ready: $dmg (version $ver, build $build)"
echo "SHA-256: $sum"
echo "Publish (docs/RELEASING.md):"
echo "  git tag v$ver && git push origin v$ver"
echo "  gh release create v$ver \"$dmg\" build/release/Blabbit.dmg \"$updates/appcast.xml\" --title \"Blabbit $ver\" --notes-file docs/release-notes/$ver.md"
