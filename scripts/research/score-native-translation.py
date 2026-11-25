#!/usr/bin/env python3
"""Score pinned native translation helpers on external FLORES fixtures. No network access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import re
import selectors
import subprocess
import time
import unicodedata

from sacrebleu.metrics import CHRF

FLORES = {'en': 'eng_Latn', 'de': 'deu_Latn', 'fr': 'fra_Latn', 'es': 'spa_Latn',
          'si': 'sin_Sinh', 'ta': 'tam_Taml', 'hi': 'hin_Deva', 'bn': 'ben_Beng', 'ur': 'urd_Arab',
          'ar': 'arb_Arab', 'zh': 'zho_Hans', 'ja': 'jpn_Jpan', 'ko': 'kor_Hang'}
ARCHIVE_SHA = 'b8b0b76783024b85797e5cc75064eb83fc5288b41e9654dabc7be6ae944011f6'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class Worker:
    def __init__(self, executable, folder, profile, error_file, threads=4, extra_arguments=()):
        self.process = subprocess.Popen([str(executable), str(folder), str(threads), profile, *extra_arguments],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=error_file)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()
        self.request_id = 0
        try:
            ready = self.read()
            self.ready = ready
            if ready.get('ready') is not True or ready.get('profile') != profile:
                raise RuntimeError('Native helper rejected the requested model profile: ' + str(ready))
        except BaseException:
            self.close()
            raise

    def read(self):
        deadline = time.monotonic() + 120
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError('Native helper response timeout')
            block = os.read(self.process.stdout.fileno(), 65536)
            if not block:
                raise RuntimeError('Native helper closed before a complete response')
            self.buffer.extend(block)
            if len(self.buffer) > 2 * 1024 * 1024:
                raise RuntimeError('Oversized native response')
        line, _, rest = self.buffer.partition(b'\n')
        self.buffer = bytearray(rest)
        return json.loads(line)

    def translate(self, texts, source, target):
        self.request_id += 1
        payload = dict(id=self.request_id, src=source, tgt=target, texts=texts)
        self.process.stdin.write(json.dumps(payload, ensure_ascii=False).encode() + b'\n')
        self.process.stdin.flush()
        result = self.read()
        if result.get('id') != self.request_id or 'error' in result:
            raise RuntimeError('Native request failed: ' + str(result))
        output = result.get('out')
        if not isinstance(output, list) or len(output) != len(texts) or not all(isinstance(x, str) for x in output):
            raise RuntimeError('Malformed native output')
        return output

    def close(self):
        self.selector.close()
        if self.process.stdin:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        if self.process.stdout:
            self.process.stdout.close()


def load_fixture(root, language, manifest):
    path = root / (FLORES[language] + '.devtest')
    expected = next(row for row in manifest['files'] if row['path'] == path.name)
    if digest(path) != expected['sha256']:
        raise ValueError('Fixture checksum mismatch: ' + path.name)
    return path.read_text().splitlines()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--model-root', required=True, type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--family', choices=['opus', 'madlad', 'nllb', 'hymt2-1.8b', 'hymt2-7b', 'translategemma-4b', 'translategemma-12b'], default='opus')
    parser.add_argument('--model-folder', type=Path)
    parser.add_argument('--pairs', nargs='+', default=['en-de', 'de-en', 'en-fr', 'fr-en', 'en-es', 'es-en'])
    parser.add_argument('--samples', type=int, default=30)
    parser.add_argument('--reference-float32', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.samples <= 1012:
        raise ValueError('Sample count must be between 1 and 1012')
    manifest = json.loads((args.fixtures / 'source.json').read_text())
    if manifest.get('archiveSHA256') != ARCHIVE_SHA:
        raise ValueError('Unexpected FLORES dataset archive')
    indices = sorted(random.Random(110).sample(range(1012), args.samples))
    result = dict(family=args.family, helperSHA256=digest(args.helper), dataset=manifest,
                  indices=indices, protocol='1.1.0-translation-quality-protocol', scores=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for pair in args.pairs:
        source, target = pair.split('-')
        inputs = load_fixture(args.fixtures, source, manifest)
        references = load_fixture(args.fixtures, target, manifest)
        if len(inputs) != 1012 or len(references) != 1012:
            raise ValueError('Unexpected parallel fixture row count')
        texts = [inputs[i] for i in indices]
        gold = [references[i] for i in indices]
        profile = {'opus': 'marian', 'madlad': 'madlad', 'nllb': 'nllb'}.get(args.family, args.family)
        folder = args.model_root / ('opus-' + pair) if args.family == 'opus' else args.model_folder
        if folder is None:
            raise ValueError('--model-folder is required for this family')
        receipt = folder / 'earmark-source.json'
        provenance = json.loads(receipt.read_text()) if receipt.exists() else None
        if args.family not in {'madlad', 'nllb'} and provenance is None:
            raise ValueError('A verified checkpoint acquisition receipt is required')
        if provenance:
            for artifact in provenance['files']:
                relative = Path(artifact['path'])
                if relative.is_absolute() or '..' in relative.parts:
                    raise ValueError('Unsafe checkpoint receipt path')
                path = folder / relative
                if path.stat().st_size != artifact['size'] or digest(path) != artifact['sha256']:
                    raise ValueError('Checkpoint changed since acquisition: ' + str(relative))
        source_tag, target_tag = (FLORES[source], FLORES[target]) if args.family == 'nllb' else (source, target)
        with args.output.with_name(args.output.stem + '-' + pair + '.stderr').open('wb') as errors:
            worker = Worker(args.helper, folder, profile, errors)
            try:
                started = time.monotonic()
                outputs = []
                for start in range(0, len(texts), 8):
                    outputs += worker.translate(texts[start:start + 8], source_tag, target_tag)
                elapsed = time.monotonic() - started
            finally:
                worker.close()
        metric = CHRF(word_order=2)
        score = metric.corpus_score(outputs, [gold]).score
        shared = preserved = 0
        for text, reference, output in zip(texts, gold, outputs):
            numbers = set(re.findall(r'\b[0-9]{2,}\b', unicodedata.normalize('NFKC', text)))
            expected = numbers & set(re.findall(r'\b[0-9]{2,}\b', unicodedata.normalize('NFKC', reference)))
            actual = set(re.findall(r'\b[0-9]{2,}\b', unicodedata.normalize('NFKC', output)))
            shared += len(expected)
            preserved += len(expected & actual)
        row = dict(pair=pair, samples=len(outputs), chrfPlusPlus=score, signature=str(metric.get_signature()),
                   empty=sum(not x.strip() for x in outputs), seconds=elapsed,
                   sharedNumberTokens=shared, preservedNumberTokens=preserved)
        if provenance:
            row['model'] = provenance
        if args.reference_float32:
            if args.family != 'opus':
                raise ValueError('Float32 comparison currently supports only Marian pair packs')
            import ctranslate2
            import sentencepiece
            tokenizer = sentencepiece.SentencePieceProcessor(model_file=str(folder / 'source.spm'))
            decoder = sentencepiece.SentencePieceProcessor(model_file=str(folder / 'target.spm'))
            reference_model = ctranslate2.Translator(str(folder), device='cpu', compute_type='float32', inter_threads=1, intra_threads=4)
            pieces = [tokenizer.encode(text, out_type=str) + ['</s>'] for text in texts]
            reference_outputs = [decoder.decode(x.hypotheses[0]) for x in reference_model.translate_batch(pieces, beam_size=4, max_decoding_length=256)]
            row['float32ChrFPlusPlus'] = metric.corpus_score(reference_outputs, [gold]).score
            row['quantizedDelta'] = score - row['float32ChrFPlusPlus']
            del reference_model
        if args.family.startswith(('hymt2-', 'translategemma-')):
            # A frozen screening floor, not full precision parity or universal language coverage.
            row['passesQualityScreen'] = row['empty'] == 0 and score >= 35 and preserved == shared
        if args.family == 'opus':
            row['passesInitialFloor'] = row['empty'] == 0 and score >= 35 and 'quantizedDelta' in row and row['quantizedDelta'] >= -2
        result['scores'].append(row)
        args.output.with_name(args.output.stem + '-' + pair + '-hypotheses.json').write_text(
            json.dumps(dict(indices=indices, source=texts, reference=gold, native=outputs), ensure_ascii=False, indent=2) + '\n')
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(pair, 'chrF++', round(score, 2), 'delta', row.get('quantizedDelta'), 'empty', row['empty'], flush=True)
    if args.family.startswith(('hymt2-', 'translategemma-')):
        result['status'] = 'passed_quality_screen' if all(row['passesQualityScreen'] for row in result['scores']) else 'failed_quality_screen'
        result['quantizationParity'] = 'not_evaluated'
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    if args.family == 'opus':
        passed = all(row['passesInitialFloor'] for row in result['scores'])
        result['status'] = 'passed_initial_floor' if passed else 'failed_or_incomplete_initial_floor'
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        if not passed:
            raise SystemExit(2)


if __name__ == '__main__':
    main()
