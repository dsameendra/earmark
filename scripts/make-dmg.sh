#!/bin/bash
# Package an already signed app into the branded, deterministic Finder layout.
set -euo pipefail
if [ "$#" -ne 4 ]; then
    echo 'Usage: scripts/make-dmg.sh APP OUTPUT.dmg ARTWORK_DIRECTORY local|selfsigned|distribution' >&2
    exit 64
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -e "$2" ] || [ -L "$2" ] || [ -e "$3" ] || [ -L "$3" ]; then
    echo 'Output image and artwork directory must be new, unused paths.' >&2; exit 64
fi
app="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$1")"
dmg="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$2")"
artwork="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$3")"
mode="$4"
case "$mode" in local|selfsigned|distribution) ;; *) echo 'Invalid package mode.' >&2; exit 64 ;; esac
if [ ! -d "$app" ] || [ "$(basename "$app")" != Earmark.app ] || [ ! -f "$app/Contents/Resources/Earmark.icns" ]; then
    echo 'Expected a built Earmark.app with its compiled icon.' >&2; exit 64
fi
if [ -e "$dmg" ] || [ -L "$dmg" ] || [ -e "$artwork" ] || [ -L "$artwork" ]; then
    echo 'Output image and artwork directory must be new, unused paths.' >&2; exit 64
fi
for tool in python3 swift tiffutil hdiutil ditto; do command -v "$tool" >/dev/null; done
build_root="${EARMARK_BUILD_ROOT:-$HOME/Library/Caches/EarmarkBuild}"
dmg_python="${EARMARK_DMG_PYTHON:-$build_root/dmg-venv/bin/python}"
if [ -z "${EARMARK_DMG_PYTHON:-}" ] && [ ! -x "$dmg_python" ]; then
    python3 -m venv "$build_root/dmg-venv"
fi
if ! "$dmg_python" - "$repo_root/scripts/dmg/requirements.txt" <<'PY'
import importlib.metadata,sys
for line in open(sys.argv[1]):
 line=line.strip()
 if not line or line.startswith('#'): continue
 name,version=line.split('==')
 try: actual=importlib.metadata.version(name)
 except importlib.metadata.PackageNotFoundError: sys.exit(1)
 if actual!=version: sys.exit(1)
PY
then
    if [ -n "${EARMARK_DMG_PYTHON:-}" ]; then
        echo 'EARMARK_DMG_PYTHON must contain the pinned scripts/dmg/requirements.txt tools.' >&2; exit 64
    fi
    "$dmg_python" -m pip install --requirement "$repo_root/scripts/dmg/requirements.txt"
fi
mkdir -p "$(dirname "$dmg")"
swift "$repo_root/scripts/dmg/make-background.swift" "$artwork" "$mode"
tiffutil -cathidpicheck "$artwork/background.png" "$artwork/background@2x.png" -out "$artwork/background.tiff"
ditto "$app/Contents/Resources/Earmark.icns" "$artwork/volume.icns"
"$dmg_python" -m dmgbuild -s "$repo_root/scripts/dmg/settings.py" \
    -D "app=$app" -D "icon=$artwork/volume.icns" -D "background=$artwork/background.tiff" \
    Earmark "$dmg"
"$dmg_python" - "$artwork" <<'PY'
import hashlib,importlib.metadata,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
report={'tools':{name:importlib.metadata.version(name) for name in ['dmgbuild','ds_store','mac_alias']},
        'assets':{name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in ['background.tiff','volume.icns']},
        'windowSize':[660,420], 'iconLocations':{'Earmark.app':[170,200],'Applications':[490,200]}}
(root/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
PY
