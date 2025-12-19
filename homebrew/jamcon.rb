# Homebrew Cask formula for JamCon
#
# To use this formula:
# 1. Create a new repo: github.com/YOUR_USERNAME/homebrew-tap
# 2. Create directory: Casks/
# 3. Copy this file to: Casks/jamcon.rb
# 4. Update the sha256 with the actual value from the release
# 5. Users can then install with:
#    brew tap YOUR_USERNAME/tap
#    brew install --cask jamcon

cask "jamcon" do
  version "1.0.0"
  sha256 "REPLACE_WITH_ACTUAL_SHA256_FROM_RELEASE"

  url "https://github.com/jturnshek/JamCon/releases/download/v#{version}/JamCon-#{version}.dmg"
  name "JamCon"
  desc "Use Nintendo Joy-Con controllers as a wireless mouse and keyboard for macOS"
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
