#!/usr/bin/env bash
# Clear stale Accessibility grants and restart the app so you can grant once,
# cleanly, to the current build. Run this after every ./build.sh (an ad-hoc
# rebuild changes the code hash, which invalidates the previous grant).
set -euo pipefail

LABEL="com.arousseau.timetracker"
UID_NUM="$(id -u)"

echo "==> stopping running instances"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -f "TimeTracker.app/Contents/MacOS/timetracker" 2>/dev/null || true

echo "==> resetting Accessibility entries for $LABEL"
tccutil reset Accessibility "$LABEL" || true

echo "==> relaunching via LaunchAgent"
launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || \
    open "$HOME/Applications/TimeTracker.app"

cat <<'EOF'

Next:
  1) A prompt should appear (or open System Settings > Privacy & Security > Accessibility).
  2) If you see any old "TimeTracker" entries there, remove them (–), then enable the current one.
  3) That's it — no rebuild after granting, or the grant resets again.
EOF
