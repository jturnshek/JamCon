# Development

## Prerequisites

- Xcode 16+
- XcodeGen (`brew install xcodegen`)
- Apple Developer account (for code signing)

## Workflow

We use a script-based workflow so Accessibility permissions stay stable between builds:

1. Generate the project once:
   ```bash
   xcodegen generate
   ```
2. Build, sign, and install:
   ```bash
   ./dev.sh
   ```
3. Relaunch without rebuilding:
   ```bash
   ./relaunch.sh
   ```

The first time you run `./dev.sh`, grant Accessibility permission for `/Applications/JamCon.app`.

## Code signing

Set `SIGNING_IDENTITY` to the exact identity string shown by:

```bash
security find-identity -v -p codesigning
```

## Manual build

```bash
xcodegen generate
xcodebuild -scheme JamCon -configuration Release -derivedDataPath build
open JamCon.xcodeproj
```
