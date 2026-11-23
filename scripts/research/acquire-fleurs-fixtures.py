#!/usr/bin/env python3
"""Acquire four licensed, pinned speech smoke fixtures; no model code or credentials."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=Path.home() / 'Library/Caches/Earmark110Fixtures/fleurs')
    args = parser.parse_args()
    inventory = Path(__file__).resolve().parents[2] / 'specs/research/1.1.0-fleurs-fixtures.json'
    rows = json.loads(inventory.read_text())
    destination = args.destination.expanduser().resolve()
    destination.mkdir(parents=True, exist_ok=True)
    for row in rows:
        code = row['language']
        if code not in ('fr', 'de', 'es', 'ja') or row['license'] != 'CC-BY-4.0':
            raise ValueError('Unrecognized fixture identity or license')
        audio = destination / (code + '.wav')
        if not audio.is_file() or hashlib.sha256(audio.read_bytes()).hexdigest() != row['audioSHA256']:
            url = ('https://raw.githubusercontent.com/' + row['sourceAudioRepository'] + '/' +
                   row['sourceAudioRevision'] + '/samples/fleurs-' + code + '.wav')
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read(10 * 1024 * 1024 + 1)
            if len(data) > 10 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != row['audioSHA256']:
                raise ValueError('Fixture checksum mismatch: ' + code)
            partial = audio.with_name(audio.name + '.earmark-partial')
            partial.write_bytes(data)
            partial.replace(audio)
        (destination / (code + '.txt')).write_text(row['reference'] + '\n')
        print('Verified', code, row['audioSHA256'])
    (destination / 'manifest.json').write_text(inventory.read_text())


if __name__ == '__main__':
    main()
