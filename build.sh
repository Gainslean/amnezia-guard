#!/bin/bash
# Собирает build/AmneziaGuard.app (иконка + приложение строки меню). Root не нужен.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/AmneziaGuard.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

echo "• иконка"
swift tools/make_icon.swift build/icon.png >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "• компиляция"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework UserNotifications \
  app/*.swift -o "$APP/Contents/MacOS/AmneziaGuard"
cp app/Info.plist "$APP/Contents/Info.plist"

echo "• сторож сети (agwatch)"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" tools/agwatch.swift -o build/agwatch
codesign --force --sign - build/agwatch >/dev/null 2>&1
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "готово: $APP"
