#!/usr/bin/env python3
"""Generate finite NLLB mappings from verified local vocabulary and CLDR data; no network or model code."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re

CLDR_SHA = 'ee30563c98bb6217adebbdc97b0ca7a0ff834973011a6890cddfd83c6250e729'
# CLDR merges these into other model tokens. Preserve the checkpoint's distinct
# dialects rather than silently selecting North Levantine or generic Akan.
PRESERVE = {'ajp', 'twi'}
# This pinned conversion uses Bengali Santali; the original FLORES fixture is Ol Chiki.
REQUIRE_SCRIPT = {'sat'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vocabulary', type=Path, required=True)
    parser.add_argument('--cldr-aliases', type=Path, required=True)
    parser.add_argument('--cldr-source', type=Path, required=True)
    args = parser.parse_args()
    cldr_data = args.cldr_aliases.read_bytes()
    if hashlib.sha256(cldr_data).hexdigest() != CLDR_SHA:
        raise ValueError('Unreviewed CLDR alias data')
    aliases_data = json.loads(cldr_data)['supplemental']['metadata']['alias']['languageAlias']
    vocabulary_data = args.vocabulary.read_bytes()
    tags = [tag for tag in vocabulary_data.decode().splitlines() if re.fullmatch('[a-z]{3}_[A-Z][a-z]{3}', tag)]
    if len(tags) != 202 or len(set(tags)) != 202:
        raise ValueError('Expected exactly 202 distinct NLLB language/script tokens')
    bases = {tag: tag.split('_')[0] if tag.split('_')[0] in PRESERVE else aliases_data.get(tag.split('_')[0], {}).get('_replacement', tag.split('_')[0]) for tag in tags}
    scripts = collections.defaultdict(set)
    for tag, base in bases.items():
        scripts[base].add(tag.split('_')[1])
    codes, aliases, rows = {}, {'tw': 'twi'}, []
    for tag in tags:
        iso, script = tag.split('_')
        base = bases[tag]
        canonical = base if (len(scripts[base]) == 1 and base not in REQUIRE_SCRIPT) or tag == 'zho_Hans' else base + '-' + script
        if canonical in codes:
            raise ValueError('CLDR merged distinct checkpoint tokens: ' + canonical)
        codes[canonical] = tag
        for alias in [base + '-' + script, iso, iso + '-' + script]:
            if alias in [iso, base] and (len(scripts[base]) > 1 or base in REQUIRE_SCRIPT) and tag != 'zho_Hans':
                continue
            if alias != canonical:
                if alias in aliases and aliases[alias] != canonical:
                    raise ValueError('Ambiguous alias: ' + alias)
                aliases[alias] = canonical
        rows.append(dict(language=canonical, flores=tag))
    root = Path(__file__).resolve().parents[2]
    output = root / 'Packages/ModelStore/Sources/ModelLanguageProfiles'
    output.mkdir(exist_ok=True)
    source = '// Generated from the pinned NLLB vocabulary and Unicode CLDR aliases.\n// See Packages/ModelStore/LanguageProfiles.provenance.json.\npublic enum NLLBLanguageProfile {\n'
    for name, values in [('codes', codes), ('aliases', aliases)]:
        source += f'    public static let {name}: [String: String] = [\n'
        source += ''.join(f'        "{key}": "{value}",\n' for key, value in sorted(values.items())) + '    ]\n'
    source += '}\n'
    (output / 'NLLBLanguageProfile.swift').write_text(source)
    metadata = dict(profile='nllb-200-distilled-600M', checkpointRepository='JustFrederik/nllb-200-distilled-600M-ct2-int8',
                    checkpointRevision='302d78f00e6fdb50a1064059df7c392b735e9d05',
                    vocabularySHA256=hashlib.sha256(vocabulary_data).hexdigest(), cldr=json.loads(args.cldr_source.read_text()),
                    preservedDialectCodes=sorted(PRESERVE), explicitScriptRequired=sorted(REQUIRE_SCRIPT), tokens=rows, aliases=aliases,
                    generatedSourceSHA256=hashlib.sha256(source.encode()).hexdigest(),
                    status='token inventory and aliases; not quality certification')
    (root / 'Packages/ModelStore/LanguageProfiles.provenance.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'{len(codes)} canonical language/script identities; {len(aliases)} aliases, {len(set(bases.values()))} distinct language codes.')


if __name__ == '__main__':
    main()
