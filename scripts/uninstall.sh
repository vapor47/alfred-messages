#!/bin/zsh
set -euo pipefail
label="dev.local.alfred-messages.helper"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Library/Application Support/AlfredMessages"
rm -rf "/tmp/alfred-messages-$(id -u)" /tmp/alfred-messages-v*-"$(id -u)"(N)
printf '%s\n' 'Helper, LaunchAgent, settings, and workflow cache removed. Remove the workflow from Alfred separately.'
