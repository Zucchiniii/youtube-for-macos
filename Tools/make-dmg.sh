#!/bin/bash
# Builds YouTube Plus and packages it as a drag-to-Applications disk image.
#   ./Tools/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/YouTube Plus.app"
DMG="build/YouTube Plus.dmg"
STAGE="build/dmg-stage"
VOLUME="YouTube Plus"

echo "==> Building the app"
./build.sh >/dev/null

echo "==> Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# The app is signed ad hoc rather than with a paid Developer ID, so Gatekeeper
# will refuse the first launch unless the user opens it explicitly. Saying so
# inside the image saves everyone a scary dialog.
cat > "$STAGE/First launch.txt" <<'NOTE'
YouTube Plus — first launch
===========================

1. Drag "YouTube Plus" onto the Applications folder in this window.

2. The first time you open it, macOS will say the developer cannot be
   verified. That is expected: the app is signed ad hoc, not with a paid
   Apple Developer ID.

   To open it anyway, right-click (or Control-click) the app in
   Applications and choose "Open", then confirm.

   Only needed once. Afterwards it opens normally.

   If macOS refuses outright, clear the download quarantine flag:

       xattr -dr com.apple.quarantine "/Applications/YouTube Plus.app"

Source: https://github.com/zucchiniii/youtube-for-macos
NOTE

echo "==> Creating the disk image"
hdiutil create \
  -volname "$VOLUME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGE"

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo "==> Done: $DMG ($SIZE)"
shasum -a 256 "$DMG"
