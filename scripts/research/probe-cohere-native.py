#!/usr/bin/env python3
"""Fixed-language Cohere GGUF diagnostic on four frozen licensed FLEURS clips.

This checks a native backend candidate, not app activation, wide quality or
long-file/sustained-session acceptance. No corpus audio or hypotheses enter Git.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import struct
import time
import unicodedata
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    module = importlib.util.spec_from_file_location('speech_probe', Path(__file__).with_name('probe-native-speech.py'))
    probe = importlib.util.module_from_spec(module)
    module.loader.exec_module(probe)
    digest = probe.file_digest(args.model)
    if digest != '0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb':
        raise ValueError('Expected the pinned Cohere March 2026 Q4_K_M checkpoint')
    manifest = json.loads((args.fixtures / 'manifest.json').read_text())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result = dict(scope=__doc__, modelSHA256=digest, helperSHA256=probe.file_digest(args.helper), cases=[])
    with args.output.with_suffix('.stderr.log').open('wb') as errors:
        worker = probe.Worker(args.helper, args.model, errors, profile='cohere-2026-03')
        try:
            ready = worker.ready['ready']
            result['ready'] = ready
            if ready['canStream'] or ready['canTranslate'] or ready['canDetectLanguage'] or ready['canDiarize']:
                raise AssertionError('Unexpected Cohere profile capabilities')
            for row in manifest:
                path = args.fixtures / (row['language'] + '.wav')
                if probe.file_digest(path) != row['audioSHA256']:
                    raise ValueError('Fixture hash mismatch')
                with wave.open(str(path)) as audio:
                    if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                        raise ValueError('Expected 16 kHz mono PCM16')
                    raw = audio.readframes(audio.getnframes())
                pcm = b''.join(struct.pack('<f', sample[0] / 32768) for sample in struct.iter_unpack('<h', raw))
                worker.command('reset')
                started = time.monotonic()
                reply = worker.command('run', pcm=pcm, language=row['language'])
                if 'error' in reply:
                    raise RuntimeError(reply['error'])
                snapshot = reply['snapshot']
                if not snapshot['isFinal'] or not snapshot['text'].strip() or snapshot['words'] or snapshot['timestampKind'] != 'none':
                    raise AssertionError('Missing final text or fabricated alignment')
                def normalized(text):
                    text = unicodedata.normalize('NFKC', text).lower()
                    return ''.join(c for c in text if unicodedata.category(c)[0] in ('L', 'N'))
                reference = normalized(row['reference'])
                hypothesis = normalized(snapshot['text'])
                case = dict(language=row['language'], audioSHA256=row['audioSHA256'],
                            seconds=time.monotonic() - started,
                            CER=probe.distance(reference, hypothesis) / len(reference), snapshot=snapshot)
                result['cases'].append(case)
                args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
                print(row['language'], f"CER={case['CER']:.4f}", repr(snapshot['text']), flush=True)
            invalid = [('begin', dict(language='en')), ('run', dict(pcm=pcm)),
                       ('run', dict(pcm=pcm, language='si')), ('run', dict(pcm=pcm, language='en', targetLanguage='de'))]
            for operation, options in invalid:
                if 'error' not in worker.command(operation, **options):
                    raise AssertionError('Unsupported Cohere task/language was silently accepted')
            result['unsupportedOperationsRejected'] = True
            args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        finally:
            worker.close()


if __name__ == '__main__':
    main()
