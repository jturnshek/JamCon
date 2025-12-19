# Releasing JamCon

JamCon is distributed via GitHub Releases + a Homebrew Cask. Builds are **Apple Silicon (arm64) only**.

## Prerequisites

- Xcode 16+
- XcodeGen (`brew install xcodegen`)
- create-dmg (`brew install create-dmg`)
- Developer ID Application certificate installed in Keychain
- Notarization credentials (recommended: notarytool keychain profile)
- Optional: GitHub CLI (`brew install gh`) if you want to publish releases from the script

## One-time setup (notarization)

Create a keychain profile for `notarytool`:

```bash
xcrun notarytool store-credentials "jamcon-notary" \
  --apple-id "your@appleid.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Then export it for the release script:

```bash
export NOTARY_PROFILE="jamcon-notary"
```

## Release steps

1. Update versions in `project.yml`:
   - `MARKETING_VERSION` (e.g. `1.2.3`)
   - `CURRENT_PROJECT_VERSION` (build number)
2. Ensure the Xcode project is up to date:
   ```bash
   xcodegen generate
   ```
3. Export your signing identity (Developer ID Application):
   ```bash
   export SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   ```
4. Run the release script:
   ```bash
   ./release.sh --publish --tap /path/to/homebrew-tap --push-tap
   ```

The script will:
- Build and sign the app (arm64)
- Notarize and staple
- Create `dist/JamCon-<version>.dmg` and `.zip`
- Update the Homebrew cask with the new `version` and `sha256`
- Optionally publish a GitHub Release and push the tap

## Notes

- If you omit `--tap`, the script updates `homebrew/jamcon.rb` in this repo only.
- If you omit `--publish`, the script will build artifacts and print their paths.
