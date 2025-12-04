#!/bin/bash
set -e

echo "=== Installing JamConHID Daemon ==="

# Build the daemon
echo "Building daemon..."
swift build -c release --product jamcon-hid

# Stop existing daemon if running
echo "Stopping existing daemon (if any)..."
sudo launchctl bootout system /Library/LaunchDaemons/com.jamcon.hid.plist 2>/dev/null || true

# Install binary
echo "Installing binary to /usr/local/bin..."
sudo cp .build/release/jamcon-hid /usr/local/bin/
sudo chmod 755 /usr/local/bin/jamcon-hid

# Install plist
echo "Installing LaunchDaemon plist..."
sudo cp Resources/com.jamcon.hid.plist /Library/LaunchDaemons/
sudo chmod 644 /Library/LaunchDaemons/com.jamcon.hid.plist
sudo chown root:wheel /Library/LaunchDaemons/com.jamcon.hid.plist

# Load daemon
echo "Loading daemon..."
sudo launchctl bootstrap system /Library/LaunchDaemons/com.jamcon.hid.plist

echo ""
echo "✅ JamConHID daemon installed and running!"
echo ""
echo "Check status with:"
echo "  sudo launchctl list | grep jamcon"
echo ""
echo "View logs with:"
echo "  tail -f /var/log/jamcon-hid.log"
echo ""
echo "Test socket with:"
echo "  nc -U /var/run/jamcon-hid.sock"
