#!/bin/bash
# Builds YouTube Plus and assembles "YouTube Plus.app".
#   ./build.sh          release build
#   ./build.sh debug    debug build
#   ./build.sh run      build, then launch
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    debug) CONFIG="debug" ;;
    release) CONFIG="release" ;;
    run) LAUNCH=1 ;;
  esac
done

APP="build/YouTube Plus.app"
BINARY=".build/${CONFIG}/YouTubePlus"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/YouTubePlus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f README.md ] && cp README.md "$APP/Contents/Resources/README.md"

echo "==> Drawing icon"
rm -rf build/YouTubePlus.iconset
swift Tools/MakeIcon.swift build/YouTubePlus.iconset >/dev/null
iconutil -c icns build/YouTubePlus.iconset -o "$APP/Contents/Resources/YouTubePlus.icns"
rm -rf build/YouTubePlus.iconset

echo "==> Signing (ad hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"

if [ "$LAUNCH" -eq 1 ]; then
  echo "==> Launching"
  open "$APP"
fi
