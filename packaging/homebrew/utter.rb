# Homebrew Cask for a tap (G7): github.com/vedjrr/homebrew-tap, Casks/utter.rb.
# The main homebrew/cask repository only takes notarised apps, so Utter's
# un-notarised release lives in its own tap:
#   brew install --cask vedjrr/tap/utter
# Each release: set version and sha256 (printed by `make release`). Check with:
#   brew audit --cask vedjrr/tap/utter && brew style --fix utter.rb
cask "utter" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_Utter-#{version}.dmg" # printed by make release

  url "https://github.com/vedjrr/Utter/releases/download/v#{version}/Utter-#{version}.dmg"
  name "Utter"
  desc "Local-first dictation: hold a shortcut, speak, text appears at the cursor"
  homepage "https://github.com/vedjrr/Utter"

  livecheck do
    url "https://github.com/vedjrr/Utter/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Utter.app"

  uninstall quit: "dev.utter.mac"

  zap trash: [
    "~/Library/Application Support/Utter",
    "~/Library/Caches/dev.utter.mac",
    "~/Library/HTTPStorages/dev.utter.mac",
    "~/Library/Logs/Utter",
    "~/Library/Preferences/dev.utter.mac.plist",
  ]

  # Not notarised (no paid Apple Developer account): Gatekeeper asks once.
  caveats <<~EOS
    Utter is signed but not notarised. If macOS blocks the first launch, open
    System Settings → Privacy & Security and click "Open Anyway".
  EOS
end
