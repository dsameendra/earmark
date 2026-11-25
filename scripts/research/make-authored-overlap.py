#!/usr/bin/env python3
"""Create a private synthetic overlap probe using installed macOS voices and authored text."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import wave

TEXTS = ["The blue train leaves the station at nine o'clock. Please keep the window open until the last passenger arrives.",
         "I need three red notebooks for the meeting tomorrow. The small package belongs on the wooden table beside the door."]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    root = args.destination.expanduser().resolve()
    repo = Path(__file__).resolve().parents[2]
    if root == repo or repo in root.parents:
        parser.error('Keep generated voice audio outside the repository')
    root.mkdir(parents=True, exist_ok=True)
    manifest = root / 'source.json'
    if manifest.exists():
        existing = json.loads(manifest.read_text())
        for entry in existing['files']:
            path = root / entry['path']
            if path.stat().st_size != entry['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
                raise ValueError('A frozen fixture changed; use a new directory for a new generation')
        print(f'Using existing frozen fixture in {root}')
        return
    for voice, name, text in zip(['Daniel', 'Samantha'], ['blue-train.aiff', 'red-notebooks.aiff'], TEXTS):
        subprocess.run(['/usr/bin/say', '-v', voice, '-r', '160', '-o', str(root / name), text], check=True)
    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(root / 'blue-train.aiff'),
                    '-i', str(root / 'red-notebooks.aiff'), '-filter_complex',
                    '[0:a]aresample=16000,aformat=channel_layouts=mono,volume=0.6[a];'
                    '[1:a]aresample=16000,aformat=channel_layouts=mono,volume=0.6,adelay=3000[b];'
                    '[a][b]amix=inputs=2:duration=longest:normalize=0[out]',
                    '-map', '[out]', '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', str(root / 'mix.wav')], check=True)
    with wave.open(str(root / 'mix.wav')) as audio:
        duration = audio.getnframes() / audio.getframerate()
    metadata = dict(kind='authored synthetic overlap plumbing probe', os=platform.platform(),
                    voices=['Daniel', 'Samantha'], rate=160, secondVoiceOffsetMS=3000, gainPerVoice=0.6,
                    texts=TEXTS, durationSeconds=duration,
                    distribution='Authored text; system voice outputs retained privately and not bundled or redistributed.',
                    files=[dict(path=p.name, bytes=p.stat().st_size, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                           for p in sorted(root.iterdir()) if p.suffix in ('.aiff', '.wav')])
    (root / 'source.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'Created {duration:.3f}s synthetic probe in {root}')


if __name__ == '__main__':
    main()
