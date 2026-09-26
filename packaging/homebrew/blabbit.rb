# Homebrew Cask for a tap (G7): github.com/vedjrr/homebrew-tap, Casks/blabbit.rb.
# The main homebrew/cask repository only takes notarised apps, so Blabbit's
# un-notarised release lives in its own tap:
#   brew install --cask vedjrr/tap/blabbit
# Each release: set version and sha256 (printed by `make release`). Check with:
#   brew audit --cask vedjrr/tap/blabbit && brew style --fix blabbit.rb
cask "blabbit" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_Utter-#{version}.dmg" # printed by make release

  url "https://github.com/vedjrr/Blabbit/releases/download/v#{version}/Blabbit-#{version}.dmg"
  name "Blabbit"
  desc "Local-first dictation: hold a shortcut, speak, text appears at the cursor"
  homepage "https://github.com/vedjrr/Blabbit"

  livecheck do
    url "https://github.com/vedjrr/Blabbit/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Blabbit.app"

  uninstall quit: "dev.blabbit.mac"

  zap trash: [
    "~/Library/Application Support/Blabbit",
    "~/Library/Caches/dev.blabbit.mac",
    "~/Library/HTTPStorages/dev.blabbit.mac",
    "~/Library/Logs/Blabbit",
    "~/Library/Preferences/dev.blabbit.mac.plist",
  ]

  # Not notarised (no paid Apple Developer account): Gatekeeper asks once.
  caveats <<~EOS
    Blabbit is signed but not notarised. If macOS blocks the first launch, open
    System Settings → Privacy & Security and click "Open Anyway".
  EOS
end
