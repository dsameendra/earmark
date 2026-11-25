#!/usr/bin/env python3
"""Probe the isolated native speech worker with an authored two-speaker PCM fixture."""
import argparse
import base64
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import selectors
import struct
import subprocess
import time
import wave

TEXTS = ["The blue train leaves the station at nine o'clock. Please keep the window open until the last passenger arrives.",
         "I need three red notebooks for the meeting tomorrow. The small package belongs on the wooden table beside the door."]


def file_digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def words(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower().replace('’', "'"))


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        next_row = [i]
        for j, y in enumerate(b, 1):
            next_row.append(min(next_row[-1] + 1, row[j] + 1, row[j - 1] + (x != y)))
        row = next_row
    return row[-1]


class Worker:
    def __init__(self, helper, model, errors, profile='multitalker-v1'):
        self.process = subprocess.Popen([str(helper), str(model), profile],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()
        self.request_id = 0
        try:
            self.ready = self.read()
            if self.ready.get('version') != 1 or 'ready' not in self.ready:
                raise RuntimeError('Worker did not load the native model: ' + str(self.ready))
        except BaseException:
            self.close()
            raise

    def read(self):
        deadline = time.monotonic() + 180
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError('Speech worker timed out')
            block = os.read(self.process.stdout.fileno(), 65536)
            if not block:
                raise RuntimeError('Speech worker closed unexpectedly')
            self.buffer.extend(block)
            if len(self.buffer) > 4 * 1024 * 1024:
                raise ValueError('Oversized speech worker response')
        line, _, rest = self.buffer.partition(b'\n')
        self.buffer = bytearray(rest)
        return json.loads(line)

    def command(self, operation, pcm=None, **options):
        self.request_id += 1
        payload = dict(id=self.request_id, operation=operation, **options)
        if pcm is not None:
            payload['pcm'] = base64.b64encode(pcm).decode('ascii')
        self.process.stdin.write(json.dumps(payload).encode() + b'\n')
        self.process.stdin.flush()
        reply = self.read()
        if reply.get('id') != self.request_id or reply.get('version') != 1:
            raise ValueError('Mismatched speech worker reply')
        return reply

    def close(self):
        self.selector.close()
        if self.process.stdin:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        if self.process.stdout:
            self.process.stdout.close()


def check(snapshot, duration_ms, texts):
    segments = snapshot['segments']
    speakers = sorted({row['speaker'] for row in segments if row['speaker'] > 0})
    references = [words(text) for text in texts]
    hypotheses = [words(' '.join(row['text'] for row in segments if row['speaker'] == speaker)) for speaker in speakers]
    padded = hypotheses + [[]] * max(0, 2 - len(hypotheses))
    refs = references + [[]] * max(0, len(padded) - 2)
    cpwer = min(sum(distance(a, b) for a, b in zip(refs, order)) for order in itertools.permutations(padded)) / sum(map(len, references))
    overlap = max([0] + [max(0, min(a['endMS'], b['endMS']) - max(a['startMS'], b['startMS']))
                          for a in segments for b in segments if a['speaker'] > 0 and b['speaker'] > 0 and a['speaker'] != b['speaker']])
    valid_times = all(0 <= row['startMS'] <= row['endMS'] <= duration_ms + 50
                      for row in [*segments, *snapshot['words'], *snapshot['speakerTurns']])
    passed = len(speakers) == 2 and cpwer <= .25 and overlap >= 2000 and valid_times and snapshot['isFinal']
    return dict(cpWER=cpwer, speakerCount=len(speakers), maxCrossSpeakerSegmentOverlapMS=overlap,
                validInputRelativeTimes=valid_times, passesInitialProbe=passed, timestampKind=snapshot['timestampKind'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--fixture', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--reference-manifest', type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(args.fixture)) as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise ValueError('Expected 16 kHz mono int16 WAV')
        raw = audio.readframes(audio.getnframes())
    pcm = b''.join(struct.pack('<f', sample[0] / 32768) for sample in struct.iter_unpack('<h', raw))
    texts = TEXTS
    scope = 'synthetic authored structural/semantic probe; not natural-meeting accuracy or real-time acceptance'
    if args.reference_manifest:
        reference = json.loads(args.reference_manifest.read_text())
        if reference.get('fixtureSHA256') != hashlib.sha256(args.fixture.read_bytes()).hexdigest():
            raise ValueError('The reference manifest does not match this frozen fixture')
        texts = reference['texts']
        if len(texts) != 2 or not all(isinstance(text, str) and 0 < len(text) <= 20000 for text in texts):
            raise ValueError('Expected two bounded reference transcripts')
        scope = reference['scope']
    mode = os.environ.get('TRANSCRIBE_MULTITALKER_MODE', 'kernel')
    if mode not in ('kernel', 'masked'):
        raise ValueError('Unsupported supervision mode')
    result = dict(protocol=1, supervisionMode=mode, fixtureSHA256=hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
                  helperSHA256=hashlib.sha256(args.helper.read_bytes()).hexdigest(),
                  modelSHA256=file_digest(args.model), texts=texts,
                  scope=scope)
    with args.output.with_suffix('.stderr.log').open('wb') as errors:
        worker = Worker(args.helper, args.model, errors)
        try:
            result['ready'] = worker.ready
            assert 'error' in worker.command('feed', pcm=pcm[:32000])
            assert 'error' in worker.command('run', pcm=pcm[:32000], language='en', targetLanguage='de')
            offline = worker.command('run', pcm=pcm, language='en', diarize=True)
            if 'error' in offline:
                raise RuntimeError(offline['error'])
            result['offline'] = check(offline['snapshot'], len(pcm) / 64, texts)
            overlap = worker.ready['ready']['canStreamWithSpeakers']
            rejected = worker.command('begin', language='en', diarize=True)
            result['streamingOverlapSupported'] = overlap
            if overlap:
                assert 'error' not in rejected
            else:
                assert 'error' in rejected
                assert 'error' not in worker.command('begin', language='en', diarize=False)
            assert 'error' in worker.command('feed', pcm=struct.pack('<f', float('nan')))
            # Invalid input abandons the stream. A clean begin must work again.
            assert 'error' not in worker.command('begin', language='en', diarize=overlap)
            revisions = []
            for offset in range(0, len(pcm), 8000 * 4):
                update = worker.command('feed', pcm=pcm[offset:offset + 8000 * 4])
                if 'error' in update:
                    raise RuntimeError(update['error'])
                revisions.append(update['snapshot']['revision'])
            final = worker.command('finish')
            if 'error' in final:
                raise RuntimeError(final['error'])
            result['streaming'] = check(final['snapshot'], len(pcm) / 64, texts)
            result['monotonicRevisions'] = revisions == sorted(revisions)
            result['resetSucceeded'] = 'error' not in worker.command('reset')
            args.output.with_suffix('.snapshots.json').write_text(json.dumps(dict(offline=offline, final=final), indent=2) + '\n')
        finally:
            worker.close()
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key not in ('texts', 'ready')}, indent=2))
    if not all(result[mode]['passesInitialProbe'] for mode in ('offline', 'streaming')) or not result['monotonicRevisions']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()
