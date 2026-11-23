#!/usr/bin/env python3
"""Acquire audited native-test artifacts outside the user model store. Never executes repository code."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path, PurePosixPath
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, default=Path('specs/research/1.1.0-checkpoints.json'))
    parser.add_argument('--repo', required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--include', action='append', required=True)
    args = parser.parse_args()
    checkpoint = next(x for x in json.loads(args.inventory.read_text())['checkpoints'] if x['repo'] == args.repo)
    revision = checkpoint['revision']
    if len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision):
        raise ValueError('An immutable checkpoint revision is required')
    selected = [x for x in checkpoint['files'] if any(x['path'] == prefix or x['path'].startswith(prefix + '/') for prefix in args.include)]
    if not selected:
        raise ValueError('No audited artifacts match the requested paths')
    destination = args.destination.expanduser().resolve()
    destination.mkdir(parents=True, exist_ok=True)

    def acquire(info):
        relative = PurePosixPath(info['path'])
        if relative.is_absolute() or '..' in relative.parts or '\\' in str(relative):
            raise ValueError('Unsafe artifact path')
        target = destination.joinpath(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.resolve().is_relative_to(destination):
            raise ValueError('Artifact escapes the destination')
        expected = info.get('sha256')
        def digest(file):
            with file.open('rb') as stream:
                return hashlib.file_digest(stream, 'sha256').hexdigest()
        if target.is_file() and target.stat().st_size == info['size']:
            actual = digest(target)
            if expected is None or actual == expected:
                return dict(path=str(relative), size=info['size'], sha256=actual)
        url = 'https://huggingface.co/' + checkpoint['repo'] + '/resolve/' + revision + '/' + urllib.parse.quote(str(relative))
        partial = target.with_name(target.name + '.earmark-partial')
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=120) as response, partial.open('wb') as output:
                    while block := response.read(1024 * 1024):
                        output.write(block)
                if partial.stat().st_size != info['size']:
                    raise ValueError('Artifact size mismatch: ' + str(relative))
                actual = digest(partial)
                if expected and actual != expected:
                    raise ValueError('Artifact checksum mismatch: ' + str(relative))
                partial.replace(target)
                print('Verified', relative, info['size'], flush=True)
                return dict(path=str(relative), size=info['size'], sha256=actual)
            except Exception:
                if attempt == 2:
                    raise
        raise AssertionError('unreachable')

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        artifacts = list(pool.map(acquire, selected))
    report = dict(repository=checkpoint['repo'], revision=revision, files=artifacts,
                  status='acquired and integrity checked; native inference and quality acceptance remain separate')
    (destination / 'earmark-source.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Acquired', len(artifacts), 'files to', destination, flush=True)


if __name__ == '__main__':
    main()
