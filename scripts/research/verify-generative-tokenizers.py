#!/usr/bin/env python3
"""Compare actual GGUF prompt IDs with pinned data-only tokenizer/Jinja references. Never loads tensor weights."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

from jinja2.sandbox import ImmutableSandboxedEnvironment
from tokenizers import Tokenizer

CASES = [('en', 'de', 'The meeting starts tomorrow at 09:30.'),
         ('ja', 'en', '明日の会議は午前9時に始まります。'),
         ('zh-Hant', 'en', '請不要取消編號 AB-104 的訂單。'),
         ('ar', 'en', 'لا تلغ الطلب رقم AB-104.'),
         ('ta', 'en', 'ஆர்டர் AB-104 ஐ ரத்து செய்ய வேண்டாம்.')]
PROFILES = [('hymt2-1.8b', 'hymt18-q4', 'hymt18-tokenizer'),
            ('hymt2-7b', 'hymt7-q4', 'hymt7-tokenizer'),
            ('translategemma-4b', 'gemma4-q4', 'gemma-template'),
            ('translategemma-12b', 'gemma12-q4', 'gemma-template')]


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def receipt(folder):
    metadata = json.loads((folder / 'earmark-source.json').read_text())
    for row in metadata['files']:
        path = folder / row['path']
        if path.stat().st_size != row['size'] or digest(path) != row['sha256']:
            raise ValueError('Acquisition receipt mismatch: ' + str(path))
    return metadata


def reject(message):
    raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--model-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    module_spec = importlib.util.spec_from_file_location('native_quality', root / 'scripts/research/score-native-translation.py')
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    environment = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
    environment.globals['raise_exception'] = reject
    report = dict(scope='five multilingual prompt/tokenizer samples per exact GGUF; not quantization or translation quality acceptance',
                  helperSHA256=digest(args.helper), profiles=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for profile, model_name, tokenizer_name in PROFILES:
        folder = args.model_root / model_name
        reference = args.model_root / tokenizer_name
        model_receipt, tokenizer_receipt = receipt(folder), receipt(reference)
        config = json.loads((reference / 'tokenizer_config.json').read_text())
        tokenizer = Tokenizer.from_file(str(reference / 'tokenizer.json'))
        template = environment.from_string((reference / 'chat_template.jinja').read_text())
        row = dict(profile=profile, model=model_receipt, reference=tokenizer_receipt, cases=[])
        with args.output.with_name(profile + '-tokenizer.stderr').open('wb') as errors:
            worker = module.Worker(args.helper, folder, profile, errors, threads=1, extra_arguments=('--tokenizer-only',))
            try:
                if worker.ready.get('tokenizerOnly') is not True:
                    raise RuntimeError('Expected a vocabulary-only native diagnostic')
                row['header'] = worker.ready
                for source, target, text in CASES:
                    if profile.startswith('translategemma'):
                        content = [dict(type='text', source_lang_code=source, target_lang_code=target, text=text)]
                    else:
                        target_name = {'en': 'English', 'de': 'German'}[target]
                        content = f'Translate the following text into {target_name}. Note that you should only output the translated result without any additional explanation:\n\n{text}'
                    prompt = template.render(messages=[dict(role='user', content=content)], add_generation_prompt=True,
                                             bos_token=config['bos_token'], eos_token=config['eos_token'])
                    expected = tokenizer.encode(prompt, add_special_tokens=False).ids
                    worker.request_id += 1
                    payload = dict(id=worker.request_id, op='tokens', texts=[text], src=source, tgt=target)
                    worker.process.stdin.write(json.dumps(payload, ensure_ascii=False).encode() + b'\n'); worker.process.stdin.flush()
                    reply = worker.read()
                    if reply.get('id') != worker.request_id or 'error' in reply:
                        raise RuntimeError('Native tokenizer failed: ' + str(reply))
                    actual = reply['tokens'][0]
                    case = dict(source=source, target=target, matches=actual == expected, expected=expected, actual=actual,
                                referencePrompt=prompt, nativePrompt=reply['prompts'][0])
                    row['cases'].append(case)
                    print(profile, source, target, 'matches', case['matches'], 'tokens', len(actual), '/', len(expected), flush=True)
                worker.request_id += 1
                worker.process.stdin.write(json.dumps(dict(id=worker.request_id, src='en', tgt='de', texts=['Hello.'])).encode() + b'\n')
                worker.process.stdin.flush()
                reply = worker.read()
                row['inferenceRejected'] = reply.get('id') == worker.request_id and 'Tokenizer-only diagnostics' in reply.get('error', '')
            finally:
                worker.close()
        report['profiles'].append(row)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    report['passed'] = all(row['inferenceRejected'] and all(case['matches'] for case in row['cases']) for row in report['profiles'])
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    if not report['passed']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()
