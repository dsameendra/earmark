#!/usr/bin/env python3
"""Canary native ASR/direct speech translation diagnostic; no app activation.

Use the already-frozen French/German/Spanish FLEURS samples. Match their
parallel English FLORES references before decoding; never use a translator's
output as the reference. Detailed text remains outside Git.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import struct
import time
import unicodedata
import wave


def normalized(text):
    return ''.join(c for c in unicodedata.normalize('NFKC', text).lower() if unicodedata.category(c)[0] in ('L', 'N'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('helper', 'model', 'fixtures', 'flores', 'english-fixture-manifest', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    module = importlib.util.spec_from_file_location('speech_probe', Path(__file__).with_name('probe-native-speech.py'))
    probe = importlib.util.module_from_spec(module)
    module.loader.exec_module(probe)
    digest = probe.file_digest(args.model)
    if digest != '49e0a67e219bec95a254c2348460b6350e75a7ac6f93a131e48244b4c7cb53b9':
        raise ValueError('Expected the pinned Canary v2 Q4_K_M checkpoint')
    manifest = json.loads((args.fixtures / 'manifest.json').read_text())
    english = (args.flores / 'eng_Latn.devtest').read_text().splitlines()
    cases = []
    for row in manifest:
        language = row['language']
        if language not in ('fr', 'de', 'es'):
            continue
        source = {'fr': 'fra_Latn', 'de': 'deu_Latn', 'es': 'spa_Latn'}[language]
        path = args.flores / (source + '.devtest')
        lines = path.read_text().splitlines()
        indices = [i for i, text in enumerate(lines) if normalized(text) == normalized(row['reference'])]
        if len(indices) != 1 or len(lines) != len(english):
            raise ValueError('Expected one exact normalized parallel reference match')
        cases.append(dict(row, audioPath=args.fixtures / (language + '.wav'),
                          targets=[None, 'en'], references={language: row['reference'], 'en': english[indices[0]]},
                          floresIndex=indices[0], sourceReferenceSHA256=probe.file_digest(path)))
    if len(cases) != 3:
        raise ValueError('Expected three frozen supported-language fixtures')
    source = json.loads(args.english_fixture_manifest.read_text())
    row = next(item for item in source['sources'] if item['id'] == 1904)
    # The frozen normalized FLEURS transcript ends in "year", while FLORES
    # ends in "years". Permit only that documented final plural difference.
    indices = [i for i, text in enumerate(english) if normalized(text) in
               (normalized(row['transcription']), normalized(row['transcription']) + 's')]
    if len(indices) != 1:
        raise ValueError('Expected the frozen English parallel sentence')
    receipt = next(item for item in source['files'] if item['path'] == 'source-1904.wav')
    references = {'en': english[indices[0]]}
    for language, name in [('fr', 'fra_Latn'), ('de', 'deu_Latn'), ('es', 'spa_Latn')]:
        references[language] = (args.flores / (name + '.devtest')).read_text().splitlines()[indices[0]]
    cases.append(dict(language='en', reference=row['transcription'], references=references,
                      audioPath=args.english_fixture_manifest.parent / 'source-1904.wav',
                      audioSHA256=receipt['sha256'], targets=[None, 'fr', 'de', 'es'], floresIndex=indices[0],
                      sourceReferenceSHA256=probe.file_digest(args.flores / 'eng_Latn.devtest')))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result = dict(scope=__doc__, modelSHA256=digest, helperSHA256=probe.file_digest(args.helper),
                  englishReferenceSHA256=probe.file_digest(args.flores / 'eng_Latn.devtest'), cases=[])
    with args.output.with_suffix('.stderr.log').open('wb') as errors:
        worker = probe.Worker(args.helper, args.model, errors, profile='canary-v2')
        try:
            result['ready'] = worker.ready['ready']
            for row in cases:
                path = row['audioPath']
                if probe.file_digest(path) != row['audioSHA256']:
                    raise ValueError('Fixture hash mismatch')
                with wave.open(str(path)) as audio:
                    if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                        raise ValueError('Expected 16 kHz mono PCM16')
                    raw = audio.readframes(audio.getnframes())
                pcm = b''.join(struct.pack('<f', sample[0] / 32768) for sample in struct.iter_unpack('<h', raw))
                for target in row['targets']:
                    translation = target is not None
                    worker.command('reset')
                    options = dict(language=row['language'])
                    if translation:
                        options['targetLanguage'] = target
                    started = time.monotonic()
                    reply = worker.command('run', pcm=pcm, **options)
                    if 'error' in reply:
                        raise RuntimeError(reply['error'])
                    snapshot = reply['snapshot']
                    if not snapshot['isFinal'] or not snapshot['text'].strip():
                        raise AssertionError('Missing final text')
                    reference = row['references'][target] if translation else row['reference']
                    case = dict(language=row['language'], targetLanguage=target, translation=translation, audioSHA256=row['audioSHA256'],
                                floresIndex=row['floresIndex'], sourceReferenceSHA256=row['sourceReferenceSHA256'],
                                reference=reference, seconds=time.monotonic() - started, snapshot=snapshot)
                    if not translation:
                        case['CER'] = probe.distance(normalized(reference), normalized(snapshot['text'])) / len(normalized(reference))
                    case['validInputRelativeTimes'] = all(0 <= item['startMS'] <= item['endMS'] <= len(pcm) / 64
                        for item in [*snapshot['segments'], *snapshot['words'], *snapshot['speakerTurns']])
                    result['cases'].append(case)
                    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
                    if not case['validInputRelativeTimes']:
                        raise AssertionError('Invalid input-relative timing')
                    print(row['language'], 'AST->' + target if translation else 'ASR', case.get('CER'), repr(snapshot['text']), flush=True)
            for source, target in [('de', 'fr'), ('en', 'en'), ('en', 'lv'), ('lv', 'en'), ('ja', 'en')]:
                if 'error' not in worker.command('run', pcm=pcm, language=source, targetLanguage=target):
                    raise AssertionError('Unsupported direction was silently accepted')
            result['unsupportedDirectionsRejected'] = True
            args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        finally:
            worker.close()


if __name__ == '__main__':
    main()
