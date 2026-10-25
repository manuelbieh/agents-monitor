#!/usr/bin/env bash
# Builds "Agents Monitor.app". Pass --install to copy it to /Applications, or to
# ~/Applications when /Applications isn't writable.
# Signs with the keychain's "Developer ID Application" identity (or CODESIGN_IDENTITY) and
# falls back to ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Agents Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos14" macos/Monitor.swift macos/main.swift -o "build/AgentsMonitor-$arch"
done
lipo -create build/AgentsMonitor-arm64 build/AgentsMonitor-x86_64 -output "$APP/Contents/MacOS/AgentsMonitor"
rm build/AgentsMonitor-arm64 build/AgentsMonitor-x86_64

cp macos/Info.plist "$APP/Contents/Info.plist"
cp public/index.html "$APP/Contents/Resources/index.html"
cp macos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ && !found { print $2; found = 1 }')}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP, signed by ${IDENTITY:-ad-hoc}"

if [[ "${1:-}" == "--install" ]]; then
  # macOS 27 identifies the menu bar item of an app outside /Applications by its binary path,
  # and menu bar managers such as Bartender can't show or move such an item.
  DEST=/Applications
  [[ -w "$DEST" ]] || DEST=~/Applications
  pkill -x AgentsMonitor || true
  mkdir -p "$DEST"
  rm -rf "$DEST/Agents Monitor.app"
  if [[ "$DEST" == /Applications && -d ~/Applications/"Agents Monitor.app" ]]; then
    rm -rf ~/Applications/"Agents Monitor.app"
    echo "Removed the earlier install in ~/Applications. Tick Launch at login again if you used it."
  fi
  cp -R "$APP" "$DEST/"
  open "$DEST/Agents Monitor.app"
  echo "Installed to $DEST/Agents Monitor.app"
fi
