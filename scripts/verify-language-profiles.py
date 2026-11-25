#!/usr/bin/env python3
"""Verify the finite, generated NLLB language inventory shared by catalog and native adapters."""
import hashlib
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
metadata = json.loads((root / 'Packages/ModelStore/LanguageProfiles.provenance.json').read_text())
source = root / 'Packages/ModelStore/Sources/ModelLanguageProfiles/NLLBLanguageProfile.swift'
if metadata['checkpointRevision'] != '302d78f00e6fdb50a1064059df7c392b735e9d05':
    raise ValueError('Unreviewed NLLB checkpoint revision')
if metadata['cldr']['revision'] != '7d2b9cb11cec08f4d333ad73209deb3df0711c3b' or metadata['cldr']['sha256'] != 'ee30563c98bb6217adebbdc97b0ca7a0ff834973011a6890cddfd83c6250e729':
    raise ValueError('Unreviewed language alias data')
if hashlib.sha256(source.read_bytes()).hexdigest() != metadata['generatedSourceSHA256']:
    raise ValueError('Generated language source changed without its provenance')
rows = metadata['tokens']
if len(rows) != 202 or len({row['language'] for row in rows}) != 202 or len({row['flores'] for row in rows}) != 202:
    raise ValueError('NLLB token identities were omitted or merged')
if not all(re.fullmatch('[a-z]{3}_[A-Z][a-z]{3}', row['flores']) for row in rows):
    raise ValueError('Malformed NLLB language/script token')
codes = {row['language']: row['flores'] for row in rows}
if any(target not in codes or alias in codes for alias, target in metadata['aliases'].items()):
    raise ValueError('Language aliases shadow a canonical identity or escape the inventory')
expected = '// Generated from the pinned NLLB vocabulary and Unicode CLDR aliases.\n// See Packages/ModelStore/LanguageProfiles.provenance.json.\npublic enum NLLBLanguageProfile {\n'
for name, values in [('codes', codes), ('aliases', metadata['aliases'])]:
    expected += f'    public static let {name}: [String: String] = [\n'
    expected += ''.join(f'        "{key}": "{value}",\n' for key, value in sorted(values.items())) + '    ]\n'
expected += '}\n'
if source.read_text() != expected:
    raise ValueError('Generated language table differs from its source inventory')
if not (root / 'App/Resources/LanguageDataLicences.txt').is_file():
    raise ValueError('Unicode language data notice is missing')
print(f'NLLB language inventory: 202 distinct token identities and {len(metadata["aliases"])} finite aliases verified.')
