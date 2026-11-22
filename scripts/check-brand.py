"""Guard the compiled-icon source against divergence from the locked Main board."""
from pathlib import Path
import json
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
board = (root / 'specs/design/m8-mockups/static/Main.html').read_text()
board_flap = re.search(r'd="(M72 0V24[^"]+)"', board).group(1)
ns = {'svg': 'http://www.w3.org/2000/svg'}
for appearance in ['curl', 'curl-dark']:
    tree = ET.parse(root / f'App/Earmark.icon/Assets/{appearance}.svg')
    flap = next(p.attrib['d'] for p in tree.findall('svg:path', ns) if p.attrib['d'].startswith('M72 0V24'))
    assert flap == board_flap, f'{appearance}: folded corner differs from Main board (a square flap hides the diagonal fold)'
    assert any(p.attrib['d'] == 'M72 0H100V28Z' for p in tree.findall('svg:path', ns)), '28 percent corner shadow missing'
source = ET.parse(root / 'Brand/icon-light.svg')
native = ET.parse(root / 'App/Earmark.icon/Assets/tile.svg')
for tree, name in [(source, 'gE'), (native, 'tile')]:
    stops = tree.find(f'.//svg:linearGradient[@id="{name}"]', ns).findall('svg:stop', ns)
    values = [(float(s.attrib['offset']), s.attrib['stop-color']) for s in stops]
    assert values == [(0.0, '#E8794A'), (0.55, '#C44B16'), (1.0, '#8F360E')], 'Ember gradient or middle stop differs'
icon = json.loads((root / 'App/Earmark.icon/icon.json').read_text())
assert icon['groups'][0]['layers'][-1]['name'] == 'tile', 'Icon Composer layers are front-to-back; tile must be behind the mark'
print('Brand geometry matches Main: triangular 28% curl, exact three-stop Ember tile, mark layers visible.')
