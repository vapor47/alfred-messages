#!/bin/zsh
set -euo pipefail
umask 077
source_dir="${0:A:h}"
if [[ -d "$source_dir/../workflow/Messages Helper.app" ]]; then source_dir="${source_dir:h}/workflow"; fi
state_dir="$HOME/Library/Application Support/AlfredMessages"
agent_dir="$HOME/Library/LaunchAgents"
label="dev.local.alfred-messages.helper"
app="$state_dir/Messages Helper.app"
mkdir -p "$state_dir" "$agent_dir"
chmod 700 "$state_dir"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
if [[ -d "$app" ]]; then rm -rf "$app"; fi
/usr/bin/ditto "$source_dir/Messages Helper.app" "$app"
agent="$agent_dir/$label.plist"
rm -f "$agent"
/usr/bin/plutil -create xml1 "$agent"
/usr/bin/plutil -insert Label -string "$label" "$agent"
/usr/bin/plutil -insert ProgramArguments -json '["placeholder","daemon"]' "$agent"
/usr/bin/plutil -replace ProgramArguments.0 -string "$app/Contents/MacOS/MessagesHelper" "$agent"
/usr/bin/plutil -insert RunAtLoad -bool YES "$agent"
/usr/bin/plutil -insert KeepAlive -bool YES "$agent"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$agent"
/usr/bin/plutil -insert StandardOutPath -string /dev/null "$agent"
/usr/bin/plutil -insert StandardErrorPath -string /dev/null "$agent"
chmod 600 "$agent"
launchctl bootstrap "gui/$(id -u)" "$agent"
printf '%s\n' "Installed $app" "Grant Full Disk Access to this app, then restart with:" "launchctl kickstart -k gui/$(id -u)/$label" "Optional Contacts setup: \"$app/Contents/MacOS/MessagesHelper\" permissions"
