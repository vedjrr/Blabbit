# Releasing Utter

A release is a notarised DMG on a GitHub release plus an EdDSA-signed Sparkle appcast next to it. Existing installs find the update through `SUFeedURL` (`https://github.com/vedjrr/Utter/releases/latest/download/appcast.xml`) and verify it with `SUPublicEDKey` before installing.

## One-time setup

1. **Developer ID certificate.** Apple Developer account → Certificates → "Developer ID Application". Install it in the login keychain. Check with:
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
2. **Notarisation credentials** (an app-specific password from appleid.apple.com):
   ```sh
   xcrun notarytool store-credentials utter-notary --apple-id <you@example.com> --team-id <TEAMID>
   ```
3. **Sparkle signing key.** It is already created, in the login keychain under account `dev.utter.mac`. Its public half is `SUPublicEDKey` in `app/Resources/Info.plist`. Back up the private key somewhere safe; without it you can't ship updates to existing installs:
   ```sh
   app/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.utter.mac -x ~/utter-sparkle-private-key   # store it in your password manager, then delete the file
   ```
   On a new Mac, import it with `generate_keys --account dev.utter.mac -f <file>`. Never generate a new key for an existing app: installs would reject updates signed with it.

## Each release

1. Bump `CFBundleShortVersionString` (e.g. `0.2.0`) and `CFBundleVersion` (always increasing: `2`, `3`, …) in `app/Resources/Info.plist`. Commit.
2. Check: `make test` (unlocked, with the lid open, so the AX and live-audio suites run) and `make bench`.
3. Build, sign, notarise, staple, and write the appcast:
   ```sh
   UTTER_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" UTTER_NOTARY_PROFILE=utter-notary make dmg
   ```
   This produces `build/updates/Utter-<version>.dmg` and `build/updates/appcast.xml`. Keep `build/updates/` between releases: `generate_appcast` adds each new DMG to the same feed.
4. Tag and publish:
   ```sh
   git tag v<version> && git push origin v<version>
   gh release create v<version> build/updates/Utter-<version>.dmg build/updates/appcast.xml --title "Utter <version>" --notes-file <notes.md>
   ```
   The feed URL points at `releases/latest/download/appcast.xml`, so it must be attached to the newest release.
5. Verify from a clean account or Mac: download the DMG, drag it to Applications, and open it. There must be no Gatekeeper warning (`spctl -a -vv /Applications/Utter.app` → "Notarized Developer ID"). Then in an older install choose **Check for Updates…**.
6. Homebrew: set `version` and `sha256` (`shasum -a 256 build/updates/Utter-<version>.dmg`) in `packaging/homebrew/utter.rb`, run `brew audit --new --cask utter`, and open the PR (or push to your tap).

## Notes

- Signing is done inside-out without `--deep`: Sparkle's `Downloader.xpc` keeps its entitlements (`--preserve-metadata=entitlements`), and `--deep` would strip them.
- The app has hardened runtime with one entitlement, `com.apple.security.device.audio-input` (ADR-011). It is not sandboxed, because global event taps and Accessibility insertion don't work in the sandbox.
- Models are not bundled. Users download them in the Model Manager (pinned Hugging Face revisions, SHA-256 checked).
