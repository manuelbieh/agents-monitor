#!/usr/bin/env bash
# Builds "Agents Monitor.app". Pass --install to copy it to ~/Applications.
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
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x AgentsMonitor || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Agents Monitor.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"Agents Monitor.app"
  echo "Installed to ~/Applications/Agents Monitor.app"
fi
