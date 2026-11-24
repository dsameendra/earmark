#!/usr/bin/env python3
"""Native fixed/automatic language and incremental-stream checkpoint diagnostic.

Uses the frozen four FLEURS clips already used for general Qwen. This small
diagnostic does not activate a catalog entry or certify language-wide quality.
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
    if probe.file_digest(args.model) != '41c99fa5fb6f3d35f68e79adc3e755eca2232a8d921178bd647b71194792b8fd':
        raise ValueError('Expected the pinned Nemotron 3.5 Q4_K_M checkpoint')
    manifest = json.loads((args.fixtures / 'manifest.json').read_text())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result = dict(scope=__doc__, modelSHA256=probe.file_digest(args.model),
                  helperSHA256=probe.file_digest(args.helper), cases=[])
    with args.output.with_suffix('.stderr.log').open('wb') as errors:
        worker = probe.Worker(args.helper, args.model, errors, profile='nemotron-3.5')
        try:
            result['ready'] = worker.ready
            for row in manifest:
                path = args.fixtures / (row['language'] + '.wav')
                if probe.file_digest(path) != row['audioSHA256']:
                    raise ValueError('Fixture hash mismatch')
                with wave.open(str(path)) as audio:
                    if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                        raise ValueError('Expected 16 kHz mono PCM16')
                    raw = audio.readframes(audio.getnframes())
                pcm = b''.join(struct.pack('<f', sample[0] / 32768) for sample in struct.iter_unpack('<h', raw))
                for automatic in (False, True):
                    for streaming in (False, True):
                        worker.command('reset')
                        options = {} if automatic else dict(language=row['language'])
                        started = time.monotonic()
                        updates = []
                        if streaming:
                            reply = worker.command('begin', **options)
                            if 'error' in reply:
                                raise RuntimeError(reply['error'])
                            for offset in range(0, len(pcm), 32000):
                                reply = worker.command('feed', pcm=pcm[offset:offset + 32000])
                                if 'error' in reply:
                                    raise RuntimeError(reply['error'])
                                updates.append(reply['snapshot'])
                            reply = worker.command('finish')
                        else:
                            reply = worker.command('run', pcm=pcm, **options)
                        if 'error' in reply:
                            raise RuntimeError(reply['error'])
                        snapshot = reply['snapshot']
                        if not snapshot['isFinal'] or not snapshot['text'].strip():
                            raise AssertionError('Missing final transcript')
                        if snapshot.get('language', '').split('-')[0] != row['language']:
                            raise AssertionError('Missing or incorrect model language tag')
                        def normalized(text):
                            text = unicodedata.normalize('NFKC', text).lower()
                            return ''.join(c for c in text if unicodedata.category(c)[0] in ('L', 'N'))
                        reference = normalized(row['reference'])
                        hypothesis = normalized(snapshot['text'])
                        case = dict(language=row['language'], automatic=automatic, streaming=streaming,
                                    audioSHA256=row['audioSHA256'], seconds=time.monotonic() - started,
                                    CER=probe.distance(reference, hypothesis) / len(reference),
                                    validInputRelativeTimes=all(0 <= item['startMS'] <= item['endMS'] <= len(pcm) / 64
                                        for item in [*snapshot['segments'], *snapshot['words'], *snapshot['speakerTurns']]),
                                    snapshot=snapshot, updates=updates)
                        result['cases'].append(case)
                        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
                        if not case['validInputRelativeTimes']:
                            raise AssertionError('Native output timing exceeds the actual input')
                        print(row['language'], 'auto' if automatic else 'fixed', 'stream' if streaming else 'file',
                              f"CER={case['CER']:.4f}", snapshot.get('language'), repr(snapshot['text']), flush=True)
            for language in ('el-GR', 'en-AU', 'zh-Hant'):
                if 'error' not in worker.command('run', pcm=pcm, language=language):
                    raise AssertionError('Unsupported language was silently accepted')
            result['unsupportedLanguagesRejected'] = True
            args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        finally:
            worker.close()


if __name__ == '__main__':
    main()
