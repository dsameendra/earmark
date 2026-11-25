"""Collect licences from the resolved source checkouts without copying vendor source or model weights."""
from pathlib import Path
import argparse
parser=argparse.ArgumentParser();parser.add_argument('checkouts',type=Path);args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
sections=['Earmark third-party software notices\n\nModel weights are downloaded separately; their licences and attributions appear in Models.\n']
for checkout in sorted(args.checkouts.iterdir()):
 if not checkout.is_dir():continue
 licences=sorted(p for p in checkout.iterdir() if p.is_file() and (p.name.upper().startswith('LICENSE') or p.name.upper().startswith('COPYING')))
 for licence in licences:
  sections.append(f'\n{checkout.name}: {licence.name}\n'+('='*60)+'\n'+licence.read_text(errors='replace'))
sections.append('\n'+(root/'Packages/NLLBNative/Vendor/LICENSES.txt').read_text())
for notice in sorted((root/'NativeRuntime/ModelLicences').glob('*.txt')):
 sections.append('\n'+notice.read_text())
output=root/'App/Resources/ThirdPartyNotices.txt';output.parent.mkdir(exist_ok=True)
output.write_text('\n'.join(line.rstrip() for line in '\n'.join(sections).splitlines())+'\n');print(output)
