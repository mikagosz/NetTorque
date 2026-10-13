#!/bin/bash
# Builds NetTorque (Release), installs it and starts it.
#
# Installs to ~/Applications unless the untracked file .install-dir names another folder
# (one line, a path); --no-open installs without starting the app. Signs with the identity
# set in the Xcode project when that certificate is in your keychain, otherwise ad hoc.
# CODE_SIGN_IDENTITY in the environment overrides both.
set -euo pipefail
cd "$(dirname "$0")"

# Only Xcode-beta is installed and xcode-select points at the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcode-select -p | grep -q '\.app/'; then
  export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | head -1)/Contents/Developer"
fi

OPEN=1
if [ "${1:-}" = "--no-open" ]; then OPEN=0; fi
TARGET="$HOME/Applications"
if [ -f .install-dir ]; then TARGET="$(head -n 1 .install-dir)"; fi

./Tests/check.sh
SIGN=()
PROJECT_ID="$(grep -m1 -o 'CODE_SIGN_IDENTITY = [0-9A-F]*' NetTorque.xcodeproj/project.pbxproj | cut -d' ' -f3)"
if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
  SIGN=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
# No -v: find-identity -v hides self-signed certificates.
elif ! security find-identity -p codesigning | grep -q "$PROJECT_ID"; then
  echo "Signing certificate from the project not found — signing ad hoc."
  SIGN=(CODE_SIGN_IDENTITY=-)
fi
LOG="$(mktemp)"
# ${SIGN[@]+...}: macOS bash 3.2 treats an empty array as unbound under set -u.
if ! xcodebuild -project NetTorque.xcodeproj -scheme NetTorque -configuration Release \
     -derivedDataPath build/dd build ${SIGN[@]+"${SIGN[@]}"} > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" || tail -20 "$LOG"
  echo "Build failed — nothing installed. Full log: $LOG"
  exit 1
fi
grep -E "BUILD SUCCEEDED" "$LOG"
APP="build/dd/Build/Products/Release/NetTorque.app"

# Stop only the copy installed at TARGET, by PID — never by name.
for PID in $(pgrep -f "$TARGET/NetTorque.app/Contents/MacOS/NetTorque" || true); do kill "$PID"; done
mkdir -p "$TARGET/NetTorque.app"
rsync -a --delete "$APP/" "$TARGET/NetTorque.app/"
if [ "$OPEN" = 1 ]; then open "$TARGET/NetTorque.app"; fi
echo "Installed: $TARGET/NetTorque.app"
codesign -dvv "$TARGET/NetTorque.app" 2>&1 | grep -m1 -E "^Authority=|^Signature=adhoc" || true
