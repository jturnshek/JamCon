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

## Diagnostic log

JamCon writes semantic events and five-second input-health aggregates to:

```text
~/Library/Logs/JamCon/JamCon.log
```

The writer is asynchronous and rotates across the current file plus two
archives at 512 KB each, so persistent diagnostics stay below approximately
1.5 MB. Follow the current log through rotations with:

```bash
tail -F ~/Library/Logs/JamCon/JamCon.log
```

Search the complete retained window with:

```bash
rg 'ERROR|\[Health\]' ~/Library/Logs/JamCon/JamCon.log*
```

Raw HID reports are not written to this log. Live Debug has a separate bounded
20,000-report trace ring that can be exported explicitly when an incident needs
packet-level analysis.

Health summaries separate measurements that JamCon can prove:

- `queue` is raw HID callback receipt to engine-queue start.
- `processing` is engine-queue start to completion, including synthetic event posting.
- `inputAge` is present only when the physical report carries or is delivered with
  an unambiguously associated timestamp. Raw Joy-Con, Sense, and mouse report
  callbacks currently report `inputAge=n/a`; host receipt time is never presented
  as physical input time.
- Joy-Con `transport` summaries compare callback rate with accepted unique-packet
  rate, count exact duplicate deliveries, and show the unitless timer-tick deltas
  carried by current packets. The timer is diagnostic evidence, not a clock or
  an estimate of absolute physical input latency.

## Manual build

```bash
xcodegen generate
xcodebuild -scheme JamCon -configuration Release -derivedDataPath build
open JamCon.xcodeproj
```
