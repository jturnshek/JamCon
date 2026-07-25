# Local release packaging

JamCon does not use GitHub Actions or another hosted build service. All build,
signing, notarization, packaging, and validation steps run on a maintainer's
local Mac. Regular users should clone the repository and follow the
source-install instructions in `README.md`.

The optional process below produces **Apple Silicon (arm64) only** artifacts
when a maintainer deliberately needs local release packaging.

## Prerequisites

- Xcode 16+
- XcodeGen (`brew install xcodegen`)
- create-dmg (`brew install create-dmg`)
- Developer ID Application certificate installed in Keychain
- Notarization credentials (recommended: notarytool keychain profile)
- Optional: GitHub CLI (`brew install gh`) if you want to publish releases from the script

## Local release config (recommended)

Create a local `release.env` (ignored by git) from the example:

```bash
cp release.env.example release.env
```

Then edit it to set:
- `SIGNING_IDENTITY`
- `NOTARY_PROFILE`
- `HOMEBREW_TAP`
- `TAP_REPO` (path to your local tap clone)
- `RELEASE_PUBLISH` (set to `1` for auto-publish)
- `RELEASE_PUSH_TAP` (set to `1` to auto-push the tap)
- `RELEASE_TAG` / `RELEASE_PUSH_TAG` (set to `1` to auto-tag releases)
- `CODESIGN_TIMESTAMP_URL` (override timestamp server if HTTPS is blocked)
- `RELEASE_BUMP` (set to `patch`, `minor`, or `major` for auto version bump)
- `RELEASE_PUSH_BRANCH` (set to `1` to push the branch after bumping)
- `RELEASE_SYNC_LOCAL_CASK` (set to `1` to keep `homebrew/jamcon.rb` in sync)

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
3. Run the release script:
   ```bash
   ./release.sh --publish --tap /path/to/homebrew-tap --push-tap
   ```

The script will:
- Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (when `RELEASE_BUMP` is set)
- Build and sign the app (arm64)
- Notarize and staple
- Create `dist/JamCon-<version>.dmg` and `.zip`
- Update the Homebrew cask with the new `version` and `sha256`
- Optionally publish a GitHub Release and push the tap

## Notes

- If you omit `--tap`, the script updates `homebrew/jamcon.rb` in this repo only.
- If you omit `--publish`, the script will build artifacts and print their paths.
