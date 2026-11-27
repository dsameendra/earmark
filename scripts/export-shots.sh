#!/bin/bash
# Exports the named screenshot attachments of an xcresult as PNGs: scripts/export-shots.sh <xcresult> <out dir> <name fragment>...
set -euo pipefail
result=$1; out=$2; shift 2
rm -rf "$out"; mkdir -p "$out"
xcrun xcresulttool export attachments --path "$result" --output-path "$out" >/dev/null 2>&1
python3 - "$out" "$@" <<'PY'
import json, os, shutil, sys
out = sys.argv[1]; names = sys.argv[2:]
for test in json.load(open(os.path.join(out, 'manifest.json'))):
    for a in test.get('attachments', []):
        n = a['suggestedHumanReadableName']
        if any(k in n for k in names):
            dst = os.path.join(out, n.split('_')[0] + '.png')
            shutil.copy(os.path.join(out, a['exportedFileName']), dst)
            print(dst)
PY
