#!/bin/bash
# Quick relaunch script (no rebuild)

pkill -x JamCon 2>/dev/null || true
sleep 0.5
open /Applications/JamCon.app
echo "✅ Relaunched JamCon"
