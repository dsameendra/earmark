#!/usr/bin/env python3
"""Exercise every mapped NLLB language token in both English directions on one frozen FLORES row. Not quality acceptance."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile

ARCHIVE_SHA = 'b8b0b76783024b85797e5cc75064eb83fc5288b41e9654dabc7be6ae944011f6'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    metadata_path = root / 'Packages/ModelStore/LanguageProfiles.provenance.json'
    metadata = json.loads(metadata_path.read_text())
    if digest(args.archive) != ARCHIVE_SHA:
        raise ValueError('FLORES archive checksum mismatch')
    if digest(args.model / 'shared_vocabulary.txt') != metadata['vocabularySHA256']:
        raise ValueError('Checkpoint vocabulary differs from the recorded mapping source')
    module_spec = importlib.util.spec_from_file_location('native_quality', root / 'scripts/research/score-native-translation.py')
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    report = dict(scope='native execution on one frozen parallel FLORES row; not independent translation quality or latency acceptance',
                  rowIndex=0, datasetArchiveSHA256=ARCHIVE_SHA, helperSHA256=digest(args.helper), missingMatchingFixtures=[],
                  inventorySHA256=digest(metadata_path), modelSHA256=digest(args.model / 'model.bin'), cases=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    texts = {}
    with tarfile.open(args.archive, 'r:gz') as archive:
        for row in metadata['tokens']:
            try:
                member = archive.getmember('./flores200_dataset/devtest/' + row['flores'] + '.devtest')
            except KeyError:
                report['missingMatchingFixtures'].append(dict(token=row['flores'], reason='No matching script fixture in the pinned original FLORES archive; no substitution performed'))
                continue
            if not member.isfile() or not 0 < member.size < 2 * 1024 * 1024:
                raise ValueError('Invalid dataset member')
            with archive.extractfile(member) as stream:
                data = stream.read()
            lines = data.decode('utf-8').splitlines()
            if len(lines) != 1012:
                raise ValueError('Unexpected parallel row count')
            texts[row['flores']] = lines[0]
    with args.output.with_suffix('.stderr').open('wb') as errors:
        worker = module.Worker(args.helper, args.model, 'nllb', errors, threads=1)
        try:
            for row in metadata['tokens']:
                tag = row['flores']
                if tag == 'eng_Latn' or tag not in texts:
                    continue
                for source, target in [('eng_Latn', tag), (tag, 'eng_Latn')]:
                    case = dict(source=source, target=target, original=texts[source], reference=texts[target])
                    try:
                        output = worker.translate([texts[source]], source, target)[0]
                        case.update(output=output, nonempty=bool(output.strip()))
                    except Exception as error:
                        case.update(error=str(error), nonempty=False)
                    report['cases'].append(case)
                args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
                print(tag, 'nonempty', sum(x['nonempty'] for x in report['cases'][-2:]), '/2', flush=True)
        finally:
            worker.close()
    report['status'] = 'matched_fixture_native_requests_completed' if all(x['nonempty'] for x in report['cases']) else 'native_request_failures'
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
