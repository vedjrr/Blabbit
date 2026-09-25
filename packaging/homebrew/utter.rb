# Homebrew Cask draft (G7). To publish: fill in the version and sha256 of the
# notarised DMG from `make dmg`, then open a PR against Homebrew/homebrew-cask
# (or host it in a tap: vedjrr/homebrew-utter). Check with:
#   brew audit --new --cask utter && brew style --fix utter.rb
cask "utter" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_Utter-#{version}.dmg" # shasum -a 256 build/updates/Utter-0.1.0.dmg

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
end
