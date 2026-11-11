#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HOME/Applications/GateSwitch.app}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

if pgrep -x GateSwitch >/dev/null 2>&1; then
  killall GateSwitch || true
  sleep 0.4
fi
if pgrep -x SoftRouterToggle >/dev/null 2>&1; then
  killall SoftRouterToggle || true
  sleep 0.4
fi

if [[ ! -f "$ROOT/AppIcon.icns" ]]; then
  iconutil -c icns "$ROOT/AppIcon.iconset" -o "$ROOT/AppIcon.icns"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -O \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK" \
  -framework SwiftUI -framework AppKit \
  -o "$APP/Contents/MacOS/GateSwitch" \
  "$ROOT/GateSwitch.swift"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/helper/soft-router-toggle" "$APP/Contents/Resources/soft-router-toggle"
cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod 755 "$APP/Contents/MacOS/GateSwitch" "$APP/Contents/Resources/soft-router-toggle"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
xattr -cr "$APP" 2>/dev/null || true

# Replace the previous app name if it is still around
if [[ -d "$HOME/Applications/SoftRouterToggle.app" ]]; then
  rm -rf "$HOME/Applications/SoftRouterToggle.app"
fi

echo "Built $APP"
