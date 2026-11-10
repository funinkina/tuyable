#!/bin/sh
# usage: ./build.sh [install]   — builds build/Tuyable.app; `install` copies to ~/Applications and launches
set -e
cd "$(dirname "$0")"
APP=build/Tuyable.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
xcrun swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk -O -swift-version 5 -target arm64-apple-macos14 -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/Tuyable"
codesign -s - --force "$APP"
if [ "$1" = install ]; then
  pkill -x Tuyable || true
  rm -rf ~/Applications/Tuyable.app && mkdir -p ~/Applications && cp -R "$APP" ~/Applications/
  open ~/Applications/Tuyable.app
fi
