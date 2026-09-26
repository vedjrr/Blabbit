#!/usr/bin/env bash
# Release packaging (docs/RELEASING.md): Developer ID signing (inside-out, no
# --deep, as Sparkle requires) → DMG → notarise → staple → EdDSA-signed
# Sparkle appcast.
# Needs: BLABBIT_DEVELOPER_ID="Developer ID Application: Name (TEAMID)", and a
# notarytool keychain profile named in BLABBIT_NOTARY_PROFILE
# (xcrun notarytool store-credentials <profile>). The Sparkle EdDSA private key
# must be in the login keychain under account dev.blabbit.mac (generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."
app=build/Blabbit.app
ver=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' app/Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' app/Resources/Info.plist)
updates=build/updates
dmg="$updates/Blabbit-$ver.dmg"
sparkle_bin=app/.build/artifacts/sparkle/Sparkle/bin

if [[ -z "${BLABBIT_DEVELOPER_ID:-}" ]]; then
  echo "Cannot make a notarised DMG: set BLABBIT_DEVELOPER_ID to your 'Developer ID Application: …' signing identity." >&2
  echo "Without an Apple Developer Program membership, use 'make release' instead (docs/RELEASING.md)." >&2
  exit 2
fi
# Only a Developer ID certificate can be notarised; an Apple Development one would
# sign fine and then fail at Apple after the upload.
if [[ "$BLABBIT_DEVELOPER_ID" != "Developer ID Application: "* ]]; then
  echo "Cannot make a notarised DMG: '$BLABBIT_DEVELOPER_ID' is not a 'Developer ID Application: …' identity." >&2
  exit 2
fi
# Exact match, quotes included, so a prefix of another identity doesn't pass.
if ! security find-identity -v -p codesigning | grep -qF "\"$BLABBIT_DEVELOPER_ID\""; then
  echo "Cannot make a notarised DMG: identity '$BLABBIT_DEVELOPER_ID' is not in your keychain." >&2
  exit 2
fi
if [[ -z "${BLABBIT_NOTARY_PROFILE:-}" ]]; then
  echo "Cannot notarise: set BLABBIT_NOTARY_PROFILE to a profile created with 'xcrun notarytool store-credentials'." >&2
  exit 2
fi
# Check the credentials before signing and uploading anything.
if ! xcrun notarytool history --keychain-profile "$BLABBIT_NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Cannot notarise: the notarytool profile '$BLABBIT_NOTARY_PROFILE' doesn't work (xcrun notarytool history failed)." >&2
  exit 2
fi
if ! "$sparkle_bin/generate_keys" --account dev.blabbit.mac -p >/dev/null 2>&1; then
  echo "Cannot sign the update feed: no Sparkle key for account dev.blabbit.mac in the keychain (see docs/RELEASING.md)." >&2
  exit 2
fi

sign() { codesign --force --timestamp --options runtime --sign "$BLABBIT_DEVELOPER_ID" "$@"; }
fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$fw/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$fw/XPCServices/Downloader.xpc"
sign "$fw/Autoupdate"
sign "$fw/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign --entitlements app/Resources/Blabbit.entitlements "$app"
codesign --verify --strict --deep --verbose=2 "$app"

mkdir -p "$updates"
rm -f "$dmg"
staging=$(mktemp -d)
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Blabbit" -srcfolder "$staging" -ov -format UDZO "$dmg"
rm -rf "$staging"
codesign --timestamp --sign "$BLABBIT_DEVELOPER_ID" "$dmg"

xcrun notarytool submit "$dmg" --keychain-profile "$BLABBIT_NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"

# The appcast lists every DMG in build/updates, each with an EdDSA signature
# made with the keychain key; the app checks it against SUPublicEDKey.
"$sparkle_bin/generate_appcast" --account dev.blabbit.mac \
  --download-url-prefix "https://github.com/vedjrr/Blabbit/releases/download/v$ver/" "$updates"
echo "Release ready: $dmg (version $ver, build $build) and $updates/appcast.xml"
echo "Upload both to the GitHub release v$ver (see docs/RELEASING.md)."
