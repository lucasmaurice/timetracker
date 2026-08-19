#!/usr/bin/env bash
# Build a release binary, assemble TimeTracker.app, and ad-hoc code-sign it.
# Ad-hoc signing gives the bundle a stable identity so the Accessibility grant
# persists across rebuilds (as long as the signature stays the same).
set -euo pipefail

cd "$(dirname "$0")"
APP="TimeTracker.app"
DEST="$HOME/Applications"

echo "==> swift build -c release"
swift build -c release

BIN=".build/release/timetracker"
[ -f "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/timetracker"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Stamp the build identity (short SHA + dirty flag) into CFBundleVersion so the running app can
# show exactly what's running — every rebuild changes the code hash anyway (see the signing note
# below), and this session alone has hit more than one "is this build actually the latest" bug.
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    GIT_SHA="${GIT_SHA}-dirty"
fi
plutil -replace CFBundleVersion -string "$GIT_SHA" "$APP/Contents/Info.plist"

# Ad-hoc signing with a stable bundle identifier. Note: the code hash still changes
# each rebuild, so after a rebuild you must re-grant Accessibility. The helper
# scripts/reset-accessibility.sh resets the permission cleanly for that.
echo "==> ad-hoc signing"
codesign --force --deep --identifier ca.justereseau.timetracker --sign - "$APP"

echo "==> installing to $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/$APP"
rm -rf "$APP"   # don't leave a duplicate bundle in the repo (confuses Spotlight)

echo
echo "Built: $DEST/$APP"
echo "To run at login, install the LaunchAgent:  ./scripts/install-launchagent.sh"
echo

# Every rebuild changes the code hash, invalidating the previous Accessibility grant — reset it
# and relaunch so you can grant once, cleanly, to this build (see scripts/reset-accessibility.sh).
./scripts/reset-accessibility.sh
