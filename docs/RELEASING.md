# Releasing Say Less

Say Less ships on **GitHub Releases** (and the website in `website/`), without the paid Apple Developer Program. A release is a DMG signed with the maintainer's Apple Development certificate, **not notarised**, plus an EdDSA-signed Sparkle appcast next to it. Installed copies find updates through `SUFeedURL` (`https://github.com/vedjrr/SayLess/releases/latest/download/appcast.xml`) and check them against `SUPublicEDKey` before installing.

What that means for people installing it:
- The first open needs **System Settings → Privacy & Security → Open Anyway** (or `xattr -dr com.apple.quarantine /Applications/SayLess.app`). README and the website say so.
- Updates through Sparkle don't need that step again.
- Because every version is signed with the same certificate, the app's designated requirement doesn't change, so macOS keeps the Microphone and Accessibility permissions across updates. An ad-hoc signature would lose them every time; `make release` refuses one unless `SAYLESS_ALLOW_ADHOC=1`. When the Apple Development certificate is renewed (yearly), users grant Accessibility once more.
- The signature shows the certificate's name (`Apple Development: <Apple ID email>`) to anyone who inspects the app.

If you join the Apple Developer Program later, `make dmg` (below, "Notarised release") produces a notarised DMG instead, with no Gatekeeper step.

## One-time setup

1. **Signing certificate.** Already present: "Apple Development: …" in the login keychain (`security find-identity -v -p codesigning`). `make build` uses it automatically; set `SAYLESS_SIGN_IDENTITY` to use another.
2. **Sparkle signing key.** It is already created, in the login keychain under account `dev.sayless.mac`. Its public half is `SUPublicEDKey` in `app/Resources/Info.plist`. Back up the private key somewhere safe; without it you can't ship updates to existing installs:
   ```sh
   app/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.sayless.mac -x ~/sayless-sparkle-private-key   # store it in your password manager, then delete the file
   ```
   On a new Mac, import it with `generate_keys --account dev.sayless.mac -f <file>`. Never generate a new key for an existing app: installs would reject updates signed with it.
3. **Homebrew tap (optional).** Create the repository `vedjrr/homebrew-tap` with `Casks/sayless.rb` from `packaging/homebrew/sayless.rb`. homebrew/cask itself only accepts notarised apps.

## Each release

1. Bump `CFBundleShortVersionString` (e.g. `0.2.0`) and `CFBundleVersion` (always increasing: `2`, `3`, …) in `app/Resources/Info.plist`. Write `docs/release-notes/<version>.md`. Commit.
2. Check: `make test` (unlocked, with the lid open, so the AX and live-audio suites run) and `make bench`.
3. Build, sign, package and write the appcast:
   ```sh
   make release
   ```
   It checks the signature (and that nothing links Homebrew or Command Line Tools libraries), then writes `build/updates/Say Less-<version>.dmg` and `build/updates/appcast.xml`, and prints the SHA-256 and the publish commands. Keep `build/updates/` between releases: `generate_appcast` adds each new DMG to the same feed.
4. Tag and publish:
   ```sh
   git tag v<version> && git push origin v<version>
   gh release create v<version> build/updates/Say Less-<version>.dmg build/release/Say Less.dmg build/updates/appcast.xml --title "Say Less <version>" --notes-file docs/release-notes/<version>.md
   ```
   The feed URL points at `releases/latest/download/appcast.xml`, so it must be attached to the newest release.
5. Verify on another Mac or user account: download the DMG, drag Say Less to Applications, open it, use **Open Anyway** once, grant the permissions, dictate. Then in an older install choose **Check for Updates…**.
6. Homebrew tap: set `version` and `sha256` in `Casks/sayless.rb` and push.
7. Website: update the version and download link in `website/index.html` if it isn't pointing at `releases/latest`.

## Notarised release (needs the Apple Developer Program)

1. Install a "Developer ID Application" certificate and store notarisation credentials: `xcrun notarytool store-credentials sayless-notary --apple-id <you@example.com> --team-id <TEAMID>`.
2. `SAYLESS_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" SAYLESS_NOTARY_PROFILE=sayless-notary make dmg` signs with Developer ID, notarises, staples and writes the appcast. Then publish as above. There's no Gatekeeper step for users, and the cask can go to homebrew/cask.

## Notes

- Signing is done inside-out without `--deep`: Sparkle's `Downloader.xpc` keeps its entitlements (`--preserve-metadata=entitlements`), and `--deep` would strip them.
- The app has hardened runtime with one entitlement, `com.apple.security.device.audio-input` (ADR-011). It is not sandboxed, because global event taps and Accessibility insertion don't work in the sandbox.
- Models are not bundled. Users download them in the Model Manager (pinned Hugging Face revisions, SHA-256 checked).
