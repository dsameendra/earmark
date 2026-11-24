#!/usr/bin/env python3
"""Restore the existing public Sinhala regression selection outside iCloud. Research-only soundfile/numpy required."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import unicodedata
import urllib.request

import numpy as np
import soundfile as sf

ARCHIVE = 'https://openslr.trmal.net/resources/30/si_lk.tar.gz'
REFERENCES = 'https://openslr.trmal.net/resources/30/si_lk.lines.txt'
LICENCE = 'https://openslr.trmal.net/resources/30/LICENSE.txt'


def norm(text):
    return re.sub(r'\s+', ' ', unicodedata.normalize('NFC', text).replace('\u200d', '')).strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('selection', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    root = args.destination.expanduser().resolve()
    repo = Path(__file__).resolve().parents[2]
    if root == repo or repo in root.parents:
        parser.error('Keep public corpus audio outside the source repository')
    rows = [json.loads(line) for line in args.selection.read_text().splitlines() if line.strip()]
    wanted = {}
    for row in rows:
        name = row['id']
        if not re.fullmatch(r'sin_[0-9]+_[0-9]+\.wav', name) or name in wanted:
            raise ValueError('Unsafe or duplicate regression identity')
        wanted[name] = row
    if not 1 <= len(wanted) <= 100:
        raise ValueError('Expected a bounded preselected regression sample')
    root.mkdir(parents=True, exist_ok=True)
    receipt = root / 'source.json'
    if receipt.exists():
        existing = json.loads(receipt.read_text())
        if existing['selectionSHA256'] != digest(args.selection):
            raise ValueError('Different regression selection; use another destination')
        if (digest(root / 'manifest.jsonl') == existing.get('manifestSHA256')
                and all(digest(root / row['path']) == row['sha256'] for row in existing['files'])):
            print('Using verified resident Sinhala regression fixtures:', root)
            return
        raise ValueError('Restored Sinhala fixture changed')
    with urllib.request.urlopen(REFERENCES, timeout=60) as response:
        reference_bytes = response.read(1024 * 1024)
    references = {}
    for line in reference_bytes.decode('utf-8').splitlines():
        match = re.match(r'\(\s*(\S+)\s+"(.*)"\s*\)', line)
        if match:
            references[match[1] + '.wav'] = norm(match[2])
    for name, row in wanted.items():
        reference = references.get(name)
        expected = hashlib.sha256(norm(row['text']).encode()).hexdigest() if 'text' in row else row.get('referenceSHA256')
        if reference is None or hashlib.sha256(reference.encode()).hexdigest() != expected:
            raise ValueError('The existing reference does not match public SLR30: ' + name)
    files, restored = [], []
    with urllib.request.urlopen(ARCHIVE, timeout=60) as response, tarfile.open(fileobj=response, mode='r|gz') as source:
        etag = response.headers.get('ETag')
        for number, member in enumerate(source):
            if number > 10000:
                raise ValueError('Unexpected SLR30 archive layout')
            name = PurePosixPath(member.name).name
            if name not in wanted or not member.isfile():
                continue
            if not 0 < member.size <= 20 * 1024 * 1024:
                raise ValueError('Unexpected public audio size')
            stream = source.extractfile(member)
            if stream is None:
                raise ValueError('Missing audio member')
            raw = stream.read()
            if len(raw) != member.size:
                raise ValueError('Incomplete public audio')
            samples, rate = sf.read(io.BytesIO(raw), dtype='float32')
            if samples.ndim > 1:
                samples = samples.mean(1)
            if not 8000 <= rate <= 192000 or not 0 < len(samples) <= rate * 60:
                raise ValueError('Unexpected source audio dimensions')
            if rate != 16000:
                decoded = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', 'pipe:0', '-ar', '16000', '-ac', '1',
                                          '-f', 'f32le', 'pipe:1'], input=raw, capture_output=True, check=True)
                samples = np.frombuffer(decoded.stdout, dtype='<f4')
            duration = len(samples) / 16000
            if abs(duration - wanted[name]['dur']) > 1 / 16000:
                raise ValueError('Restored sample duration differs from the regression selection')
            path = root / name
            sf.write(path, samples, 16000, subtype='PCM_16')
            files.append(dict(path=name, bytes=path.stat().st_size, sha256=digest(path), rawSHA256=hashlib.sha256(raw).hexdigest()))
            row = dict(wanted.pop(name)); row['path'] = str(path); row['text'] = references[name]; restored.append(row)
            print('Restored', name, flush=True)
            if not wanted:
                break  # No full-archive checksum is claimed after stopping the stream early.
    if wanted:
        raise ValueError('The public archive did not contain every selected regression clip')
    order = {row['id']: index for index, row in enumerate(rows)}
    restored.sort(key=lambda row: order[row['id']])
    (root / 'manifest.jsonl').write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in restored))
    with urllib.request.urlopen(LICENCE, timeout=60) as response:
        (root / 'LICENSE.txt').write_bytes(response.read(100000))
    metadata = dict(dataset='OpenSLR30 Sinhala TTS', sourceURL=ARCHIVE, archiveETag=etag,
                    licence='CC-BY-SA-4.0', attribution='Copyright 2015, 2016 Google, Inc.',
                    selectionSHA256=digest(args.selection), manifestSHA256=digest(root / 'manifest.jsonl'), referencesURL=REFERENCES,
                    referencesSHA256=hashlib.sha256(reference_bytes).hexdigest(), files=files,
                    verification='Preselected identity/reference/duration and per-file hashes; partial archive transfer, no full archive checksum claimed')
    receipt.write_text(json.dumps(metadata, indent=2) + '\n')
    print('Restored complete resident regression selection:', len(restored))


if __name__ == '__main__':
    main()
