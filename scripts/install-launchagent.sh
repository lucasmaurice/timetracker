#!/usr/bin/env bash
# Install + load the LaunchAgent so TimeTracker starts at login and stays running.
set -euo pipefail

LABEL="ca.justereseau.timetracker"
BIN="$HOME/Applications/TimeTracker.app/Contents/MacOS/timetracker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Application Support/TimeTracker"

[ -x "$BIN" ] || { echo "Run ./build.sh first ($BIN not found)"; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Relaunch only on a crash; a clean Quit (menu) stays quit until next login. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOGDIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGDIR/stderr.log</string>
</dict>
</plist>
EOF

echo "Wrote $PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"
echo "Loaded $LABEL. Check the menu bar for the clock icon."
echo "Logs: $LOGDIR/stderr.log"
echo "To stop:   launchctl bootout gui/$(id -u)/$LABEL"
