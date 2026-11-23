#!/bin/bash
# Regenerate the marketing site screenshots in docs/assets/screens/ from a directory of captures.
#
# Usage: scripts/sync-site-assets.sh [SOURCE_DIR]
#   SOURCE_DIR defaults to specs/design/m8-shots/polish.
#
# Screens: home queue editor live library settings. Appearances: dark light.
# For each screen and appearance the first existing source PNG wins:
#   <screen>-<appearance>.png
#   <screen>-<appearance>-1440x900.png
#   <screen>-<appearance>-expanded.png
#   settings-general.png            (settings only; appearance-agnostic)
# A missing appearance falls back to the other one. A screen with neither is an error.
#
# Output in docs/assets/screens/: <screen>-<appearance>.webp (1600 px wide)
# and <screen>-<appearance>-800.webp (800 px wide). Needs sips and cwebp (brew install webp).
# docs/index.html declares width/height per image; update them if a new capture has a different aspect ratio.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-specs/design/m8-shots/polish}"
OUT=docs/assets/screens
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"
command -v cwebp >/dev/null || { echo "cwebp not found (brew install webp)" >&2; exit 1; }

find_src() { # screen appearance
  local s="$1" a="$2" c
  for c in "$s-$a.png" "$s-$a-1440x900.png" "$s-$a-expanded.png"; do
    if [ -f "$SRC/$c" ]; then echo "$SRC/$c"; return; fi
  done
  if [ "$s" = settings ] && [ -f "$SRC/settings-general.png" ]; then echo "$SRC/settings-general.png"; fi
  return 0
}

for s in home queue editor live library settings; do
  for a in dark light; do
    f="$(find_src "$s" "$a")"
    if [ -z "$f" ]; then
      if [ "$a" = dark ]; then o=light; else o=dark; fi
      f="$(find_src "$s" "$o")"
      if [ -n "$f" ]; then echo "note: $s-$a missing, using $o"; fi
    fi
    if [ -z "$f" ]; then echo "error: no source for $s" >&2; exit 1; fi
    for w in 1600 800; do
      sips --resampleWidth "$w" "$f" --out "$TMP/$s-$a-$w.png" >/dev/null
      suffix=""
      if [ "$w" = 800 ]; then suffix="-800"; fi
      cwebp -quiet -q 82 -alpha_q 90 -m 6 "$TMP/$s-$a-$w.png" -o "$OUT/$s-$a$suffix.webp"
    done
    echo "$s-$a <- $f"
  done
done
