# Troubleshooting

## Mouse not moving or buttons not working

1. Check Accessibility permission (Privacy & Security > Accessibility).
2. Ensure the controller is connected.
3. Verify Mouse Control is enabled.

## Cursor drifts when controller is still

Hold the controller completely still for 1-2 seconds. JamCon auto-calibrates when no movement is detected.

## Controller not connecting

1. Remove the controller from Bluetooth settings.
2. Re-pair using the controller pairing sequence.
3. Ensure no other device is trying to connect to it.

For Joy-Con 2, hold SYNC until the player lights chase and keep JamCon's Devices
screen open. Joy-Con 2 uses JamCon's custom BLE connection rather than the
original Joy-Con HID path. Avoid repeatedly reconnecting it in rapid succession:
the controller can enter a temporary radio cooldown after failed attempts.

## Collect recent diagnostics

JamCon keeps a bounded rotating diagnostic log at
`~/Library/Logs/JamCon/JamCon.log`. It contains connection and lifecycle events,
errors, and periodic report-rate/latency aggregates rather than individual HID
reports.

```bash
tail -n 200 ~/Library/Logs/JamCon/JamCon.log
rg 'ERROR|\[Health\]' ~/Library/Logs/JamCon/JamCon.log*
```

The current log and two archives consume at most approximately 1.5 MB total.

For Joy-Con timing investigations, compare `callbackRate` and `acceptedRate` in
the `transport` health lines. A nonzero `duplicates` count means macOS delivered
the same timer byte and byte-identical packet more than once; JamCon discards the
repeat. `inputAge=n/a` is expected for raw HID callbacks because receipt time is
not the physical sampling time. `queue` and `processing` remain directly measured.

The companion `gyroResponse` aggregate records one summary per active device and
five-second window. `filter.on`/`filter.off` identify the active A/B configuration;
raw, filtered, acceleration-gain, and computed cursor speeds show where response
is being attenuated. `bias.change` and `autoNeutralUpdates` expose calibration
changes that could otherwise feel like gradually changing sensitivity. Individual
gyro reports are never written to the log. Gyro setting changes are also logged as
single debounced events after the user finishes adjusting a control.

## Zoom not working in some apps

Zoom sends standard macOS magnification gestures. Some apps do not respond to these gestures.
