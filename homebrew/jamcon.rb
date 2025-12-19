# Homebrew cask mirror for JamCon.
# Canonical tap: https://github.com/jturnshek/homebrew-tap
# Install:
#   brew tap jturnshek/tap
#   brew install --cask jamcon

cask "jamcon" do
  version "1.0.0"
  sha256 "4492b7be6f9c2c2a2ac41764af8384eda96debaf0d44e74787e2bd6a2a74ae94"

  url "https://github.com/jturnshek/JamCon/releases/download/v#{version}/JamCon-#{version}.dmg"
  name "JamCon"
  desc "Use Nintendo Joy-Con and PS VR2 Sense controllers as a mouse and keyboard for macOS"
  homepage "https://github.com/jturnshek/JamCon"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "JamCon.app"

  postflight do
    # Open Accessibility preferences so user can grant permission
    system "open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  end

  zap trash: [
    "~/Library/Preferences/com.jamcon.app.plist",
  ]
end
