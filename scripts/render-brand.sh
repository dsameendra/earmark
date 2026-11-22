#!/bin/bash
# Regenerates every PNG derived from Brand/*.svg using only macOS built-ins
# (swiftc + AppKit's native SVG rendering; no rsvg/inkscape/ImageMagick needed).
#   Brand/icon-1024.png, Brand/icon-dark-1024.png   source PNGs for About/DMG art
#   App/Assets.xcassets menu bar imagesets          (18 pt @1x / @2x)
#   Brand/preview/*                                 16..1024 px renditions (ictool) and menu bar previews
#   App/Earmark.icon/Assets/{ear,arc}*.svg          filled-outline layers (scripts/outline-icon-layers.swift)
# curl*.svg layers and App/Earmark.icon/icon.json are hand-authored (not generated).
set -euo pipefail
cd "$(dirname "$0")/.."

TOOL=build/brandtool/render
mkdir -p build/brandtool Brand/preview
if [ ! -x "$TOOL" ] || [ scripts/render.swift -nt "$TOOL" ]; then
  swiftc -O scripts/render.swift -o "$TOOL"
fi
r() { "$TOOL" "$@"; }

# Layer SVGs for the Icon Composer bundle (strokes -> filled outlines).
swift scripts/outline-icon-layers.swift

r Brand/icon-light.svg Brand/icon-1024.png 1024
r Brand/icon-dark.svg Brand/icon-dark-1024.png 1024

CAT=App/Assets.xcassets
for set in MenuBarIdle:menubar-idle MenuBarRecordingDot:menubar-recording-dot; do
  name=${set%%:*}; svg=Brand/${set##*:}.svg
  mkdir -p "$CAT/$name.imageset"
  r "$svg" "$CAT/$name.imageset/$name.png" 18
  r "$svg" "$CAT/$name.imageset/$name@2x.png" 36
done

# Rendered through Icon Composer's own ictool (ships with Xcode) so previews show the real
# Default / Dark / Tinted / Clear renditions with system lighting applied.
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [ -x "$ICTOOL" ]; then
  for rend in Default Dark TintedLight TintedDark ClearLight ClearDark; do
    for s in 16 32 64 128 256 512 1024; do
      "$ICTOOL" App/Earmark.icon --export-image --output-file "Brand/preview/icon-$rend-$s.png" \
        --platform macOS --rendition "$rend" --width "$s" --height "$s" --scale 1 >/dev/null
    done
  done
else
  echo "ictool not found; skipping Icon Composer previews"
fi
# Menu bar previews at 16/32 px on the paper colour (glyph in black).
for s in 16 32; do
  r Brand/menubar-idle.svg Brand/preview/menubar-idle-$s-light.png $s $s F3EEE5
  r Brand/menubar-recording.svg Brand/preview/menubar-recording-$s-light.png $s $s F3EEE5
done
echo "Brand assets rendered."
