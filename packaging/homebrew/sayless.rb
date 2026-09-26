# Homebrew Cask for a tap (G7): github.com/vedjrr/homebrew-tap, Casks/sayless.rb.
# The main homebrew/cask repository only takes notarised apps, so Say Less's
# un-notarised release lives in its own tap:
#   brew install --cask vedjrr/tap/sayless
# Each release: set version and sha256 (printed by `make release`). Check with:
#   brew audit --cask vedjrr/tap/sayless && brew style --fix sayless.rb
cask "sayless" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_Utter-#{version}.dmg" # printed by make release

  url "https://github.com/vedjrr/SayLess/releases/download/v#{version}/SayLess-#{version}.dmg"
  name "Say Less"
  desc "Local-first dictation: hold a shortcut, speak, text appears at the cursor"
  homepage "https://github.com/vedjrr/SayLess"

  livecheck do
    url "https://github.com/vedjrr/SayLess/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "SayLess.app"

  uninstall quit: "dev.sayless.mac"

  zap trash: [
    "~/Library/Application Support/SayLess",
    "~/Library/Caches/dev.sayless.mac",
    "~/Library/HTTPStorages/dev.sayless.mac",
    "~/Library/Logs/SayLess",
    "~/Library/Preferences/dev.sayless.mac.plist",
  ]

  # Not notarised (no paid Apple Developer account): Gatekeeper asks once.
  caveats <<~EOS
    Say Less is signed but not notarised. If macOS blocks the first launch, open
    System Settings → Privacy & Security and click "Open Anyway".
  EOS
end
