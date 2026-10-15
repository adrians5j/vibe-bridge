#!/usr/bin/env bash
# Builds VibeBridge.app. Pass "install" to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product VibeBridge
BIN="$(swift build -c release --show-bin-path)/VibeBridge"

APP=build/VibeBridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VibeBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x VibeBridge || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/VibeBridge.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/VibeBridge.app
    echo "Installed to ~/Applications/VibeBridge.app"
fi
