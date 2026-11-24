#!/usr/bin/env python3
"""Verify the pinned speech framework/wrapper inventory; optionally smoke-load the compiled helper without a model."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper-path', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1] / 'Packages/SpeechNative/Vendor'
    metadata = json.loads((root / 'provenance.json').read_text())
    if (metadata.get('revision'), metadata.get('version'), metadata.get('abiHash')) != (
            'cfa237c2551a4b2d3a56ff8fe5461e3c67c51772', '0.4.2', 'f99ad4169374b8f3'):
        raise ValueError('Unreviewed native speech revision or ABI')
    if metadata.get('architectures') != ['arm64'] or metadata.get('deploymentTarget') != '26.0' or metadata.get('embeddedMetal') is not True:
        raise ValueError('Unexpected native speech build configuration')
    recorded = set()
    for entry in metadata['files']:
        relative = PurePosixPath(entry['path'])
        if relative.is_absolute() or '..' in relative.parts or '\\' in str(relative) or str(relative) in recorded:
            raise ValueError('Unsafe or duplicate native inventory entry')
        recorded.add(str(relative))
        path = root.joinpath(*relative.parts)
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Native inventory escaped its root')
        if path.stat().st_size != entry['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            raise ValueError('Native speech artifact changed: ' + str(relative))
    actual = {str(path.relative_to(root)) for path in root.rglob('*') if path.is_file() and not path.is_symlink() and path.name != 'provenance.json'}
    if actual != recorded:
        raise ValueError('Native speech inventory has missing or extra files')
    print(f'Native speech provenance: {len(recorded)} files match the pinned revision and ABI.')
    if args.helper_path:
        helper = args.helper_path.expanduser().resolve(strict=True)
        if not helper.is_file():
            raise ValueError('Expected a local compiled helper')
        result = subprocess.run([str(helper)], capture_output=True, timeout=15, check=False)
        reply = json.loads(result.stdout)
        if result.returncode != 1 or reply.get('version') != 1 or reply.get('id') != 0 or 'Expected model path' not in reply.get('error', ''):
            raise ValueError('Native speech helper failed its no-model dynamic-load smoke check')
        print('Native speech helper dynamically loaded and rejected missing arguments without loading a model.')


if __name__ == '__main__':
    main()
