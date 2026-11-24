#!/usr/bin/env python3
"""Explicit research-only download of pinned FLORES-200 devtest fixtures outside the repository."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request

URL = 'https://dl.fbaipublicfiles.com/nllb/flores200_dataset.tar.gz'
SHA256 = 'b8b0b76783024b85797e5cc75064eb83fc5288b41e9654dabc7be6ae944011f6'
LANGUAGES = ('eng_Latn', 'deu_Latn', 'fra_Latn', 'spa_Latn', 'sin_Sinh', 'tam_Taml',
             'hin_Deva', 'ben_Beng', 'urd_Arab', 'arb_Arab', 'zho_Hans', 'jpn_Jpan', 'kor_Hang')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    root = args.destination.expanduser().resolve()
    repository = Path(__file__).resolve().parents[2]
    if root == repository or repository in root.parents:
        parser.error('Keep licensed corpus text outside the source repository')
    root.mkdir(parents=True, exist_ok=True)
    archive = root / 'flores200_dataset.tar.gz'
    if not archive.exists() or digest(archive) != SHA256:
        partial = root / 'flores200_dataset.tar.gz.part'
        try:
            with urllib.request.urlopen(URL, timeout=60) as response, partial.open('wb') as output:
                shutil.copyfileobj(response, output)
            if digest(partial) != SHA256:
                raise ValueError('FLORES archive checksum mismatch')
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    files = []
    with tarfile.open(archive, 'r:gz') as source:
        for language in LANGUAGES:
            name = language + '.devtest'
            member = source.getmember('./flores200_dataset/devtest/' + name)
            if not member.isfile() or not 0 < member.size < 2 * 1024 * 1024:
                raise ValueError('Invalid fixture member: ' + name)
            stream = source.extractfile(member)
            if stream is None:
                raise ValueError('Missing fixture data: ' + name)
            data = stream.read()
            if len(data) != member.size or len(data.decode('utf-8').splitlines()) != 1012:
                raise ValueError('Invalid fixture contents: ' + name)
            path = root / name
            path.write_bytes(data)
            files.append(dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), lines=1012))
    manifest = dict(dataset='FLORES-200', url=URL, license='CC-BY-SA-4.0',
                    citation='NLLB Team, No Language Left Behind: Scaling Human-Centered Machine Translation (2022)',
                    archiveSHA256=SHA256, files=files)
    (root / 'source.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Verified {len(files)} devtest language files in {root}')


if __name__ == '__main__':
    main()
