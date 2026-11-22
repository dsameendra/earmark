# Earmark brand assets (T32)

Source of truth for the listening-ear mark. Geometry is copied from `specs/design/m8-mockups/static/Main.html`
(100-unit tile grid). Do not redraw by eye; change the numbers here and re-render.

| File | What |
| --- | --- |
| `mark.svg` | Ear and arc glyph only, ink + Ember, transparent |
| `icon-light.svg` / `icon-dark.svg` | Full tile, Ember gradient / night tile, 1024 px viewport |
| `menubar-idle.svg` | Monochrome glyph for the menu bar template image (18 pt) |
| `menubar-recording.svg` | Glyph plus recording-red dot (preview of the composed state) |
| `menubar-recording-dot.svg` | The dot alone (non-template asset composed in code) |
| `icon-1024.png`, `icon-dark-1024.png` | 1024 px sources for About and DMG art |
| `preview/` | Renditions at 16 to 1024 px through Icon Composer's `ictool`, plus 16/32 px menu bar previews |

Regenerate everything with `scripts/render-brand.sh` (macOS built-ins only: swiftc, AppKit SVG rendering, Icon Composer's ictool).

## Geometry (100 x 100 tile)

- Tile: rounded rect, corner radius 22 (`M22 0H78a22 22 0 0 1 22 22V78a22 22 0 0 1-22 22H22A22 22 0 0 1 0 78V22A22 22 0 0 1 22 0Z`). In the app icon the system supplies the squircle mask; layers are full bleed.
- Ear group transform: `translate(12 16) scale(1.15)`. This is the locked 2.5% left offset that answers the curl.
- Ear (stroke 4.8, round caps and joins): `M30 8c-9 0-16 7-16 16v6c0 5 3 7 6 10 2 2 3 4 3 7a6 6 0 0 0 11 3M30 20c-4 0-7 3-7 7`
- Arc (stroke 4.2): `M44 20a15 15 0 0 1 0 20`
- Curl, 28% of the tile at the top right: shadow triangle `M72 0H100V28Z`, flap `M72 0V24a4 4 0 0 0 4 4H100Z`, fold highlight `M72 0L100 28` (0.9 wide).
- No baked gloss or shadow. Icon Composer / macOS apply Liquid Glass lighting.

## Colour

| Role | Light | Dark |
| --- | --- | --- |
| Tile | `#E8794A` to `#C44B16` (55%) to `#8F360E` diagonal | `#2E2B27` to `#11100E` diagonal |
| Ear | `#FFFCF6` | `#F3EFE7` |
| Arc | `#FFD7BF` | `#F28A57` (Ember night) |
| Curl flap | `#FFF4EA` to `#F0BC9F` | `#FFB48C` to `#D4602A` |
| Curl shadow | `#461400` at 38% | `#000000` at 50% |
| AccentColor asset | Ember `#C44B16` | Ember night `#F28A57` |
| Recording dot | `#D1352B` in both; never Ember | |

## Menu bar glyph

- ViewBox `2.5 2.5 56 56` rendered at 18 x 18 pt (@1x 18 px, @2x 36 px). Strokes are thickened slightly (ear 5.4, arc 5.0) so it holds at 16 px.
- Dot: circle at (50, 49), r 7.5, bottom right, clear of the ear lobe.
- `MenuBarIdle` is a template image. Recording is composed in `App/EarmarkApp.swift`: the template glyph tinted with the label colour plus the non-template `MenuBarRecordingDot` asset.

## Icon Composer bundle

`App/Earmark.icon` (icon.json plus `Assets/*.svg`). The document fill is the tile gradient (Default and Dark specializations);
layers are curl, arc, ear and the full-bleed tile with `-dark` variants. Strokes must be filled outlines, so `ear*.svg` and `arc*.svg` are generated
by `scripts/outline-icon-layers.swift`. Tinted and Clear are derived by the system. The tile is the back-most layer (Icon Composer orders layers front to back); its SVG preserves the exact 55% middle Ember stop because native document gradients accept only two colors. The curl closes diagonally at `H100Z`, never `H100V0Z`: adding the extra vertical edge turns the triangular folded flap into a square. Run `python3 scripts/check-brand.py` to compare these details directly with the locked Main board. Format notes: every `*-specializations`
array must include a base entry (no `appearance`) and must replace the plain key (plain `fill` / `image-name` alongside it is ignored).
