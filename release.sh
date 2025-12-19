#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

RELEASE_ENV="${RELEASE_ENV:-./release.env}"
if [ -f "$RELEASE_ENV" ]; then
  # shellcheck source=/dev/null
  . "$RELEASE_ENV"
fi

APP_NAME="JamCon"
BUILD_DIR="build"
DIST_DIR="dist"

VERSION=""
BUMPED=0
TAP_REPO="${TAP_REPO:-}"
PUBLISH="${RELEASE_PUBLISH:-0}"
PUSH_TAP="${RELEASE_PUSH_TAP:-0}"
SKIP_NOTARY="${RELEASE_SKIP_NOTARY:-0}"
AUTO_TAG="${RELEASE_TAG:-}"
AUTO_PUSH_TAG="${RELEASE_PUSH_TAG:-}"
AUTO_BUMP="${RELEASE_BUMP:-}"
AUTO_PUSH_BRANCH="${RELEASE_PUSH_BRANCH:-}"
TIMESTAMP_URL="${CODESIGN_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"

usage() {
  cat <<'EOF'
Usage: ./release.sh [--version X.Y.Z] [--bump patch|minor|major] [--tap PATH] [--publish] [--push-tap] [--skip-notary]

Options:
  --version X.Y.Z   Verify version matches MARKETING_VERSION in project.yml
  --bump kind       Auto-bump MARKETING_VERSION (patch|minor|major)
  --tap PATH        Update the Homebrew cask at PATH (repo or Casks/jamcon.rb)
  --publish         Create a GitHub release and upload DMG/ZIP (requires gh)
  --push-tap        Commit + push the tap repo after updating the cask (use repo path)
  --skip-notary     Skip notarization (for local testing only)

Environment:
  RELEASE_ENV       Path to a local env file (default: ./release.env)
  SIGNING_IDENTITY  Developer ID Application identity (auto-detected if unset)
  TAP_REPO          Default tap path (alternative to --tap)
  HOMEBREW_TAP      Tap name used in release notes (default: "jturnshek/tap")

  NOTARY_PROFILE    Keychain profile name (created via notarytool store-credentials)
  or:
  NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH
  or:
  NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID

  RELEASE_PUBLISH   Set to 1 to publish GitHub Releases without --publish
  RELEASE_PUSH_TAP  Set to 1 to push tap updates without --push-tap
  RELEASE_SKIP_NOTARY Set to 1 to skip notarization without --skip-notary
  RELEASE_TAG       Set to 1 to auto-create a git tag when publishing
  RELEASE_PUSH_TAG  Set to 1 to push the git tag to origin
  RELEASE_BUMP      Set to patch|minor|major to auto-bump MARKETING_VERSION
  RELEASE_PUSH_BRANCH Set to 1 to push the current branch after bumping
  CODESIGN_TIMESTAMP_URL  Override the timestamp server (default: http://timestamp.apple.com/ts01)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --tap)
      TAP_REPO="${2:-}"
      shift 2
      ;;
    --publish)
      PUBLISH=1
      shift
      ;;
    --push-tap)
      PUSH_TAP=1
      shift
      ;;
    --skip-notary)
      SKIP_NOTARY=1
      shift
      ;;
    --bump)
      AUTO_BUMP="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required tool: $name"
    exit 1
  fi
}

staple_with_retry() {
  local target="$1"
  local attempts=5
  local delay=5
  local i
  for i in $(seq 1 "$attempts"); do
    if xcrun stapler staple "$target"; then
      return 0
    fi
    echo "Staple failed for $target (attempt $i/$attempts). Retrying in ${delay}s..."
    sleep "$delay"
  done
  return 1
}

require_cmd xcodebuild
require_cmd codesign
require_cmd xcrun
require_cmd ditto
require_cmd shasum

ensure_clean_git() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree has uncommitted changes. Commit or stash before releasing."
    exit 1
  fi
}

PROJECT_VERSION=$(awk -F'"' '/MARKETING_VERSION:/{print $2; exit}' project.yml)
PROJECT_BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/{print $2; exit}' project.yml)
if [ -z "$PROJECT_VERSION" ]; then
  echo "Unable to read MARKETING_VERSION from project.yml"
  exit 1
fi
if [ -z "$PROJECT_BUILD" ]; then
  echo "Unable to read CURRENT_PROJECT_VERSION from project.yml"
  exit 1
fi

if [ -n "$AUTO_BUMP" ] && [ -n "$VERSION" ]; then
  echo "Cannot use --version with --bump. Remove --version to auto-bump."
  exit 1
fi

if [ -n "$VERSION" ] && [ "$VERSION" != "$PROJECT_VERSION" ]; then
  echo "Version mismatch: project.yml has $PROJECT_VERSION, but --version is $VERSION"
  echo "Update MARKETING_VERSION in project.yml before releasing."
  exit 1
fi
VERSION="$PROJECT_VERSION"

if [ "$PUBLISH" -eq 1 ]; then
  AUTO_TAG="${AUTO_TAG:-1}"
  AUTO_PUSH_TAG="${AUTO_PUSH_TAG:-1}"
  AUTO_PUSH_BRANCH="${AUTO_PUSH_BRANCH:-1}"
fi
AUTO_TAG="${AUTO_TAG:-0}"
AUTO_PUSH_TAG="${AUTO_PUSH_TAG:-0}"
AUTO_PUSH_BRANCH="${AUTO_PUSH_BRANCH:-0}"

if [ -n "$AUTO_BUMP" ]; then
  case "$AUTO_BUMP" in
    patch|minor|major) ;;
    *)
      echo "Invalid --bump value: $AUTO_BUMP (use patch|minor|major)"
      exit 1
      ;;
  esac

  ensure_clean_git
  require_cmd git
  require_cmd xcodegen

  if [[ ! "$PROJECT_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "MARKETING_VERSION must be semver (X.Y.Z). Found: $PROJECT_VERSION"
    exit 1
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"

  case "$AUTO_BUMP" in
    patch)
      patch=$((patch + 1))
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
  esac

  new_version="${major}.${minor}.${patch}"
  if ! [[ "$PROJECT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "CURRENT_PROJECT_VERSION must be numeric. Found: $PROJECT_BUILD"
    exit 1
  fi
  new_build=$((PROJECT_BUILD + 1))

  /usr/bin/perl -0pi -e "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"${new_version}\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]+\"/CURRENT_PROJECT_VERSION: \"${new_build}\"/" project.yml
  xcodegen generate

  git add project.yml JamCon.xcodeproj/project.pbxproj
  if [ -f ".beads/.local_version" ]; then
    git add .beads/.local_version
  fi
  git commit -m "Bump version to ${new_version}"

  PROJECT_VERSION="$new_version"
  PROJECT_BUILD="$new_build"
  VERSION="$new_version"
  BUMPED=1
fi

if [ -z "${SIGNING_IDENTITY:-}" ]; then
  SIGNING_IDENTITY=$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application:/{print $2; exit}'
  )
fi
if [ -z "${SIGNING_IDENTITY:-}" ]; then
  echo "Missing SIGNING_IDENTITY. Install a Developer ID Application certificate or set SIGNING_IDENTITY."
  exit 1
fi
HOMEBREW_TAP="${HOMEBREW_TAP:-jturnshek/tap}"

NOTARY_ARGS=()
if [ "$SKIP_NOTARY" -eq 0 ]; then
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ] && [ -n "${NOTARY_KEY_PATH:-}" ]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then
    NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
  else
    echo "Missing notarization credentials."
    echo "Set NOTARY_PROFILE, or NOTARY_KEY_ID/NOTARY_ISSUER_ID/NOTARY_KEY_PATH, or NOTARY_APPLE_ID/NOTARY_PASSWORD/NOTARY_TEAM_ID."
    exit 1
  fi
fi

if [ ! -f "JamCon.xcodeproj/project.pbxproj" ]; then
  require_cmd xcodegen
  echo "Generating Xcode project..."
  xcodegen generate
fi

echo "Cleaning build artifacts..."
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "Building $APP_NAME $VERSION (arm64)..."
xcodebuild -scheme JamCon -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS=arm64

APP_PATH="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Build artifact missing at $APP_PATH"
  exit 1
fi

echo "Signing app with Developer ID..."
codesign --force --deep --sign "$SIGNING_IDENTITY" \
  --entitlements Resources/JamCon.entitlements \
  --options runtime \
  --timestamp="$TIMESTAMP_URL" \
  "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

if [ "$SKIP_NOTARY" -eq 0 ]; then
  echo "Submitting for notarization..."
  NOTARY_ZIP="$DIST_DIR/${APP_NAME}-notary.zip"
  ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" "${NOTARY_ARGS[@]}" --wait
  staple_with_retry "$APP_PATH"
fi

DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.zip"

echo "Creating DMG..."
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$APP_NAME" \
    --volicon "Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 130 200 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 410 200 \
    "$DMG_PATH" \
    "$APP_PATH" || true
fi

if [ ! -s "$DMG_PATH" ]; then
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
fi

echo "Signing DMG..."
codesign --force --sign "$SIGNING_IDENTITY" --timestamp="$TIMESTAMP_URL" "$DMG_PATH"

if [ "$SKIP_NOTARY" -eq 0 ]; then
  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait
  staple_with_retry "$DMG_PATH"
fi

echo "Creating ZIP archive..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
ZIP_SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

update_cask() {
  local cask_path="$1"
  if [ ! -f "$cask_path" ]; then
    echo "Cask not found at $cask_path"
    exit 1
  fi
  /usr/bin/perl -0pi -e "s/version \"[^\"]+\"/version \"${VERSION}\"/; s/sha256 \"[^\"]+\"/sha256 \"${DMG_SHA}\"/" "$cask_path"
}

CASK_PATH=""
if [ -n "$TAP_REPO" ]; then
  if [ -d "$TAP_REPO/Casks" ]; then
    CASK_PATH="$TAP_REPO/Casks/jamcon.rb"
  else
    CASK_PATH="$TAP_REPO"
  fi
else
  CASK_PATH="homebrew/jamcon.rb"
fi
update_cask "$CASK_PATH"

if [ "$PUSH_TAP" -eq 1 ]; then
  if [ -z "$TAP_REPO" ]; then
    echo "--push-tap requires --tap PATH"
    exit 1
  fi
  if [ ! -d "$TAP_REPO/.git" ]; then
    echo "--push-tap requires --tap to be a git repo path"
    exit 1
  fi
  git -C "$TAP_REPO" add "$CASK_PATH"
  git -C "$TAP_REPO" commit -m "jamcon ${VERSION}"
  git -C "$TAP_REPO" push
fi

if [ "$AUTO_PUSH_BRANCH" -eq 1 ] && [ "$BUMPED" -eq 1 ]; then
  require_cmd git
  git push origin HEAD
fi

if [ "$AUTO_TAG" -eq 1 ]; then
  require_cmd git
  TAG_NAME="v${VERSION}"
  if git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null 2>&1; then
    echo "Tag $TAG_NAME already exists locally."
  else
    if git ls-remote --tags origin "refs/tags/$TAG_NAME" | grep -q "$TAG_NAME"; then
      echo "Tag $TAG_NAME already exists on origin."
    else
      ensure_clean_git
      git tag -a "$TAG_NAME" -m "${APP_NAME} ${VERSION}"
      echo "Created tag $TAG_NAME."
    fi
  fi

  if [ "$AUTO_PUSH_TAG" -eq 1 ]; then
    if git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null 2>&1; then
      git push origin "$TAG_NAME"
    fi
  fi
fi

if [ "$PUBLISH" -eq 1 ]; then
  require_cmd gh
  RELEASE_NOTES="$DIST_DIR/release-notes.txt"
  cat > "$RELEASE_NOTES" <<EOF
## ${APP_NAME} ${VERSION}

### Installation
1. Download \`${APP_NAME}-${VERSION}.dmg\`
2. Drag ${APP_NAME}.app to /Applications
3. Launch ${APP_NAME} and grant Accessibility permissions

### Homebrew
\`\`\`bash
brew tap ${HOMEBREW_TAP}
brew install --cask jamcon
\`\`\`

### SHA256
DMG: ${DMG_SHA}
ZIP: ${ZIP_SHA}
EOF

  gh release create "v${VERSION}" "$DMG_PATH" "$ZIP_PATH" \
    --title "${APP_NAME} ${VERSION}" \
    --notes-file "$RELEASE_NOTES"
fi

echo "Release artifacts ready:"
echo "  DMG: $DMG_PATH"
echo "  ZIP: $ZIP_PATH"
echo "  SHA256 (DMG): $DMG_SHA"
echo "  SHA256 (ZIP): $ZIP_SHA"
