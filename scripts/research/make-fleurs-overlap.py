#!/usr/bin/env python3
"""Build a frozen, licensed two-speaker diagnostic from the pinned English FLEURS test parquet. Requires pyarrow 19.0.1."""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import wave

import pyarrow.parquet as pq

REVISION = '168de341b3db6859a9bac1c50a2ef5e3b47647e0'
PARQUET_SHA = '6428a4d04d3aac29e16b45e039bb1470a8bd7aa334cf92f7984c9c520d1f234d'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('parquet', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    source = args.parquet.expanduser().resolve()
    root = args.destination.expanduser().resolve()
    repo = Path(__file__).resolve().parents[2]
    if root == repo or repo in root.parents:
        parser.error('Keep licensed audio and references outside the source repository')
    if source.stat().st_size != 401722686 or digest(source) != PARQUET_SHA:
        raise ValueError('Unexpected FLEURS English test parquet')
    root.mkdir(parents=True, exist_ok=True)
    manifest = root / 'source.json'
    if manifest.exists():
        existing = json.loads(manifest.read_text())
        for entry in existing['files']:
            if digest(root / entry['path']) != entry['sha256']:
                raise ValueError('Frozen fixture changed')
        print('Using existing frozen FLEURS mixture:', root)
        return
    # Selection is independent of any model output: first male/female utterance in parquet order, 6-15s.
    table = pq.read_table(source, columns=['id', 'num_samples', 'gender', 'transcription'])
    selected = {}
    for index, row in enumerate(table.to_pylist()):
        if 6 * 16000 <= row['num_samples'] <= 15 * 16000 and row['gender'] in (0, 1) and row['gender'] not in selected:
            selected[row['gender']] = (index, row)
        if len(selected) == 2:
            break
    if len(selected) != 2:
        raise ValueError('Could not select the declared two-speaker diagnostic')
    audio = pq.read_table(source, columns=['audio'])
    samples, sources = [], []
    for gender in (0, 1):
        index, row = selected[gender]
        payload = audio.column('audio')[index].as_py()['bytes']
        if not 0 < len(payload) <= 10 * 1024 * 1024:
            raise ValueError('Unexpected audio member size')
        raw = root / f'source-{row["id"]}.original'
        raw.write_bytes(payload)
        target = root / f'source-{row["id"]}.wav'
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-protocol_whitelist', 'file,pipe',
                        '-i', str(raw), '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', str(target)], check=True)
        with wave.open(str(target)) as wav:
            if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()) != (1, 2, 16000, row['num_samples']):
                raise ValueError('Decoded FLEURS dimensions differ from metadata')
            values = array('h', wav.readframes(wav.getnframes()))
        if sys.byteorder != 'little':
            values.byteswap()
        peak = max(abs(value / 32768) for value in values)
        rms = math.sqrt(sum((value / 32768) ** 2 for value in values) / len(values))
        if peak == 0 or rms == 0:
            raise ValueError('Selected FLEURS fixture is silent')
        gain = min(0.45 / peak, 0.08 / rms)
        samples.append([value / 32768 * gain for value in values])
        sources.append(dict(id=row['id'], parquetRow=index, gender=gender, transcription=row['transcription'],
                            originalSHA256=hashlib.sha256(payload).hexdigest(), samples=len(values), gain=gain,
                            inputRMS=rms, inputPeak=peak))
    offset = 3 * 16000
    mixture = [0.0] * max(len(samples[0]), offset + len(samples[1]))
    for voice, start in zip(samples, [0, offset]):
        for index, value in enumerate(voice):
            mixture[start + index] += value
    if max(map(abs, mixture)) > 0.9001:
        raise ValueError('Unexpected mixture clipping')
    output = array('h', [round(value * 32767) for value in mixture])
    if sys.byteorder != 'little':
        output.byteswap()
    with wave.open(str(root / 'mix.wav'), 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000); wav.writeframes(output.tobytes())
    metadata = dict(dataset='google/fleurs', revision=REVISION, config='en_us', split='test', license='CC-BY-4.0',
                    citation='Conneau et al., FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech (2022)',
                    sourceURL=f'https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/en_us/test/0000.parquet',
                    parquetSHA256=PARQUET_SHA, selection='First male and female utterance in parquet order with duration 6-15 seconds',
                    secondVoiceOffsetMS=3000, maximumPeakPerVoice=0.45, targetRMSPerVoice=0.08,
                    sources=sources, texts=[row['transcription'] for row in sources],
                    scope='Licensed natural-voice synthetic mixture; a small diagnostic, not a natural meeting benchmark',
                    fixtureSHA256=digest(root / 'mix.wav'), durationSeconds=len(mixture) / 16000,
                    files=[dict(path=path.name, bytes=path.stat().st_size, sha256=digest(path)) for path in sorted(root.iterdir()) if path.is_file()])
    manifest.write_text(json.dumps(metadata, indent=2) + '\n')
    print('Created frozen FLEURS overlap fixture:', [row['id'] for row in sources], metadata['fixtureSHA256'])


if __name__ == '__main__':
    main()
