#!/usr/bin/env python3
"""Verify the pinned llama bridge/framework; optionally smoke-load its isolated helper."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper-path', type=Path)
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1] / 'Packages/TextGenerationNative'
    root = package / 'Vendor'
    metadata = json.loads((root / 'provenance.json').read_text())
    if metadata.get('repository') != 'https://github.com/ggml-org/llama.cpp' or metadata.get('revision') != '9578bd3fe48b793cf193c2e4615ec2f24a2ea92a':
        raise ValueError('Unreviewed native text source revision')
    if (metadata.get('architectures') != ['arm64'] or metadata.get('deploymentTarget') != '26.0'
            or metadata.get('embeddedMetal') is not True or metadata.get('networkRuntime') is not False
            or metadata.get('backends') != ['metal', 'cpu']):
        raise ValueError('Unexpected native text build configuration')
    if set(metadata['bridge']) != {'EarmarkLlama.h', 'EarmarkLlama.cpp'}:
        raise ValueError('Unexpected native text bridge inventory')
    for name, digest in metadata['bridge'].items():
        if sha256(package / 'Bridge' / name) != digest:
            raise ValueError('Native text bridge differs from its compiled artifact: ' + name)
    links = {str(p.relative_to(root)): str(p.readlink()) for p in root.rglob('*') if p.is_symlink()}
    if links != metadata.get('symlinks'):
        raise ValueError('Native framework symlink inventory changed')
    for name in links:
        if not (root / name).resolve(strict=True).is_relative_to(root.resolve()):
            raise ValueError('Native framework symlink escaped its root')
    recorded = set()
    for entry in metadata['files']:
        relative = PurePosixPath(entry['path'])
        if relative.is_absolute() or '..' in relative.parts or '\\' in str(relative) or str(relative) in recorded:
            raise ValueError('Unsafe or duplicate native text inventory entry')
        recorded.add(str(relative))
        path = root.joinpath(*relative.parts)
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Native text inventory escaped its root')
        if path.stat().st_size != entry['bytes'] or sha256(path) != entry['sha256']:
            raise ValueError('Native text artifact changed: ' + str(relative))
    actual = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and not p.is_symlink() and p.name != 'provenance.json'}
    if actual != recorded:
        raise ValueError('Native text inventory has missing or extra files')
    print(f'Native text provenance: {len(recorded)} files and both bridge sources match the pinned revision.')
    if args.helper_path:
        helper = args.helper_path.expanduser().resolve(strict=True)
        result = subprocess.run([str(helper)], capture_output=True, timeout=15, check=False)
        reply = json.loads(result.stdout)
        if result.returncode != 1 or 'Expected a local model folder' not in reply.get('error', ''):
            raise ValueError('Native text helper failed its no-model dynamic-load check')
        print('Native text helper dynamically loaded and rejected missing arguments without loading a model.')


if __name__ == '__main__':
    main()
