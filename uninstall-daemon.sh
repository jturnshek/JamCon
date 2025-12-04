#!/bin/bash
set -e

echo "=== Uninstalling JamConHID Daemon ==="

# Stop daemon
echo "Stopping daemon..."
sudo launchctl bootout system /Library/LaunchDaemons/com.jamcon.hid.plist 2>/dev/null || true

# Remove plist
echo "Removing LaunchDaemon plist..."
sudo rm -f /Library/LaunchDaemons/com.jamcon.hid.plist

# Remove binary
echo "Removing binary..."
sudo rm -f /usr/local/bin/jamcon-hid

# Remove socket
echo "Removing socket..."
sudo rm -f /var/run/jamcon-hid.sock

# Remove logs
echo "Removing logs..."
sudo rm -f /var/log/jamcon-hid.log

echo ""
echo "✅ JamConHID daemon uninstalled!"
