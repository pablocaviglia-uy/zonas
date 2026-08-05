#!/usr/bin/env bash
#
# dmg.sh — the disk image, with the window laid out the way a stranger needs it.
#
#   ./dmg.sh <version> <path/to/Zonas.app> <out.dmg>
#
# `hdiutil create -srcfolder` on its own produces a working disk image and a
# hostile one: it opens as a plain list of files, with no indication that the
# thing to do is drag one onto the other. That drag is not decoration here —
# running the app from the mounted image or from ~/Downloads puts it under App
# Translocation, which greys out "Launch at Login" forever and makes macOS ask
# for the Accessibility permission again on every single launch, each time for a
# path that no longer exists. The window has one job: make the drag obvious.
#
# The layout is set by talking to the Finder, because that is the only thing
# that writes the `.DS_Store` a disk image window is styled by. There is no API
# for it and there never has been; every project that ships a pretty .dmg does
# this, and this is why it needs a real login session rather than a build server.
set -euo pipefail

VERSION="${1:?usage: dmg.sh <version> <app> <out.dmg>}"
APP="${2:?}"
OUT="${3:?}"

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKGROUND="$RAIZ/Resources/dmg/background.tiff"
VOLUME="Zonas $VERSION"

[[ -d "$APP" ]] || { echo "no app at $APP" >&2; exit 1; }
[[ -f "$BACKGROUND" ]] || { echo "no background at $BACKGROUND" >&2; exit 1; }

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
mkdir -p "$STAGE/.background"

ditto "$APP" "$STAGE/Zonas.app"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND" "$STAGE/.background/background.tiff"

# Room to breathe: a read/write image that is too tight cannot be written to at
# all, and the slack costs nothing because the final image is compressed.
SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 20000 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE_KB}k" "$RW" >/dev/null

# -nobrowse keeps it out of the Finder's sidebar while it is being dressed;
# without -noautoopen a window appears mid-script and the AppleScript below
# fights it for focus.
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen -nobrowse "$RW" \
    | grep -E '^/dev/' | head -1 | awk '{print $1}')
MOUNT="/Volumes/$VOLUME"
trap 'hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# The Finder has to be able to see the volume to style it, so it is browsable
# for exactly as long as that takes.
hdiutil detach "$DEVICE" >/dev/null
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" \
    | grep -E '^/dev/' | head -1 | awk '{print $1}')
sleep 2

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 660 x 420 of content. The extra 28 points is the title bar, which is not
    -- part of the background picture and will crop it if it is not allowed for.
    set the bounds of container window to {240, 140, 900, 588}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    -- The centres of the outer two columns in the background picture, which
    -- is what makes the app look like it is sitting in a zone rather than
    -- beside one. 46..178 and 482..614, so 112 and 548.
    set position of item "Zonas.app" of container window to {112, 200}
    set position of item "Applications" of container window to {548, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" >/dev/null
trap 'rm -rf "$WORK"' EXIT

rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "built $OUT"
