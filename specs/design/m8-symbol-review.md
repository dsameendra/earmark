# M8 T33: symbol weight-match review

Artefact: `m8-symbol-review.png` (stock SF Symbol vs custom duotone, Regular and Semibold, 17 pt sidebar and 15 pt toolbar, each beside system text of the same size and weight, plus a 40 pt Regular pair). Regenerate with `EARMARK_WRITE_SYMBOL_SHEET=1 swift test --filter SymbolReviewSheet` in `Packages/DesignSystem`.

## How the set is built

- `Tools/generate-symbols.swift` (checked in) reads the 24 board centrelines (`Icons.dc.html`) plus the ear (`Main.dc.html`, refitted to the 18 px live area) and writes `Symbols.xcassets/<asset>.symbolset/{Contents.json,<asset>.svg}`.
- Approach: stroke-and-outline, not three-master interpolation. Each of the 27 weight x scale cells (Ultralight to Black x S/M/L) is written explicitly: the same centreline scaled onto the template (4.0 / 5.0 / 6.5 template units per board pixel for S / M / L), stroked with a weight-specific width, expanded to outlines with CoreGraphics (round caps and joins) and unioned. No point-compatible contours are needed. Template v7.0 structure (Notes, Guides with baseline, capline and margin lines, Symbols) was copied from a real SF Symbols 7 export; layer classes are `monochrome-0/1`, `hierarchical-0:primary` (ink), `hierarchical-1:secondary` (Ember). `actool` compiles all 25 into 39 renditions each; `swift build`, `swift test` and `xcodebuild` all produce `Assets.car` in the DesignSystem resource bundle.
- Stroke widths were measured, not assumed. Stock `circle` at 100 pt, Medium scale, 4x raster: Ultralight 2.25, Thin 3.75, Light 6.25, Regular 8.25, Medium 9.75, Semibold 11.0, Bold 12.75, Heavy 15.0, Black 17.25 template units. The board's Regular ink stroke (1.6 px on 24 at 5.0 units per px = 8.0) agrees with stock Regular (8.25), so the board proportions are already system-weight. Stock scale factors: S 0.80, L 1.30 for geometry, stems S 0.91, L 1.12 (applied). Accent stroke is the board ratio 2.1 / 1.6 of ink.
- Vertical placement: grid (12, 12) sits on the cap-height centre of each scale's baseline, as in stock templates; side bearings are 12.7 units at M scaled per scale.

## Measured match (100 pt, Medium scale, monochrome, alpha > 50 %)

Mean stroke thickness estimated as 2 x area / perimeter; custom includes the accent layer, which is 31 % wider than ink by design, so a small positive bias is expected.

| | Regular | Semibold |
|---|---|---|
| Median custom / stock thickness | 1.14 | 1.14 |
| Median custom / stock ink height | 0.87 | 0.88 |

The Regular-to-Semibold step is the same in custom and stock (both about +30 % thickness), so weights track the system text weight control; the custom set is consistently about 14 % heavier by this estimator, of which roughly 5 to 8 points is the wider accent layer.

What matched (ratio 0.95 to 1.12 at both weights): speaker, dictation, queue, library, meetings, earmark, models, waveform at Regular, play, record, find, ear, retry.

Custom looks heavier (ratio above 1.2 at one or both weights): liveCaptions (1.24 to 1.26), recentlyDeleted (1.24 to 1.38), settings (1.41 to 1.47), download (1.30), video (1.26 to 1.31), language (1.22 to 1.39), hidden at Semibold (1.35), export (1.2 at Regular). These are glyphs where the accent line crosses or touches the ink (a full-width bar or arrow), so strokes merge into larger blobs at small sizes.

Custom looks lighter: translate (0.69 to 0.82; the stock glyph is a filled speech bubble), home (0.90 to 0.94), record and find at Semibold (0.89 to 0.96).

Custom is smaller than stock at the same point size (about 0.87 median height, 0.67 to 0.78 for settings, queue, meetings, liveCaptions, systemAudio, recentlyDeleted, export). This is the board's 18 px live area against stock glyphs that run to the full cap-height box. Not a weight defect, but custom rows will look slightly smaller beside stock icons; keep one family per surface.

Visual read of the sheet: at 17 pt and 15 pt the Regular and Semibold pairs sit on the text baseline with matching optical weight for most rows; the ember detail is legible at 15 pt Regular. Ultralight and Black were checked only through the generator and `weightsDiffer` test (monotonic ink coverage), not by eye.

## Recommendation

- Use the custom set for the sidebar (17 pt), section headers, empty states and onboarding: Home, Queue, Meetings, Library, Record, Speaker, Dictation, Waveform, Folder, Earmark, Find, Models, Retry, Play, Ear, Translate, Language, Hidden, Export.
- Fall back to stock for 15 pt toolbar and menu items (where weight mismatch next to system text is most visible): Live captions, Recently deleted, Settings, Video, Download. Cheapest switch: render those with `DSIcon(.x).dsSymbolStyle(...)` only in sidebars and keep `systemImage:` in toolbars, or re-tune their ink stroke by 10 to 15 % in the generator (`inkStemM` scale per glyph) and re-run.
- Menu items are rendered monochrome by AppKit regardless of `DSSymbolStyle`; the duotone only shows in views.
- The risk the user accepted (custom duotone is the least native option) holds: weights track system text, but the set is visibly about 14 % heavier and 13 % smaller than stock.

## Not verified

Rendering inside a live `NavigationSplitView` sidebar and a glass toolbar, Dark appearance and Increase Contrast ember contrast (T40), Dynamic Type scaling of `DSIcon`, and Ultralight/Black by eye.
