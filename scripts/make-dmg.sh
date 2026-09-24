#!/usr/bin/env bash
# Release packaging: sign with Developer ID → DMG → notarise → staple.
# Needs: UTTER_DEVELOPER_ID="Developer ID Application: Name (TEAMID)" and a
# notarytool keychain profile (xcrun notarytool store-credentials <profile>)
# named in UTTER_NOTARY_PROFILE. See docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."
app=build/Utter.app
ver=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' app/Resources/Info.plist)
dmg="build/Utter-$ver.dmg"

if [[ -z "${UTTER_DEVELOPER_ID:-}" ]]; then
  echo "Cannot make a release DMG: set UTTER_DEVELOPER_ID to your 'Developer ID Application: …' signing identity." >&2
  echo "Available identities:" >&2
  security find-identity -v -p codesigning >&2 || true
  exit 2
fi
if ! security find-identity -v -p codesigning | grep -qF "$UTTER_DEVELOPER_ID"; then
  echo "Cannot make a release DMG: identity '$UTTER_DEVELOPER_ID' is not in your keychain." >&2
  exit 2
fi
if [[ -z "${UTTER_NOTARY_PROFILE:-}" ]]; then
  echo "Cannot notarise: set UTTER_NOTARY_PROFILE to a profile created with 'xcrun notarytool store-credentials'." >&2
  exit 2
fi

codesign --force --deep --timestamp --options runtime \
  --entitlements app/Resources/Utter.entitlements --sign "$UTTER_DEVELOPER_ID" "$app"
codesign --verify --strict --deep --verbose=2 "$app"

rm -f "$dmg"
staging=$(mktemp -d)
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Utter" -srcfolder "$staging" -ov -format UDZO "$dmg"
rm -rf "$staging"
codesign --timestamp --sign "$UTTER_DEVELOPER_ID" "$dmg"

xcrun notarytool submit "$dmg" --keychain-profile "$UTTER_NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "Release DMG ready: $dmg"
