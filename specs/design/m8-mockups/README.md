# Earmark M8 mockups (final v1)

Local copy of the Claude Design canvas **https://claude.ai/artifact/FzAtjj7ZdYAkp1WHPeFSVF** (final v1, canvas version id `1795296776-319f`). The canvas is private to the product owner; this folder is the durable copy. **Open `index.html` in a browser for the gallery.**

## Formats

| Folder | What | Use it for |
|---|---|---|
| `static/*.html` | Self-contained rendered snapshots (no JavaScript, no runtime). Fonts load from Google Fonts when online, with system fallbacks offline. Motion demos still animate (CSS). | Viewing, inspecting CSS/markup values, comparing to builds |
| `png/*.png` | 1x screenshots of each board at its frame size | Side-by-side comparison in PRs and snapshot reviews |
| `source/*.dc.html`, `source/canvas.json` | Claude Design "Design Component" sources and canvas layout | Editing and republishing in Claude Design; the source of truth for the generated files |
| `archive/` | Rejected exploration boards (logo rounds, colour options, symbol styles, Home A) | Decision record only. Never reintroduce. |
| `tools/render-mockups.mjs` | Regenerates `static/` and `png/` from `source/` | See below |

## Board index

| Board | Section | Shows | Covers | Task | Frame |
|---|---|---|---|---|---|
| [Main](static/Main.html) ([png](png/Main.png), [source](source/Main.dc.html)) | Brand | Brand identity: mark, lockups, app icon (light, dark, small), colour, type, voice | PROD | T32 | 1440 x 1340 |
| [Icons](static/Icons.html) ([png](png/Icons.png), [source](source/Icons.dc.html)) | Brand | Custom duotone symbol set (24) with asset names, construction, sizes, states | NAV | T33 | 1440 x 1280 |
| [Glass](static/Glass.html) ([png](png/Glass.png), [source](source/Glass.dc.html)) | Brand | Liquid Glass materials, glass budget, shape and depth, easing, live motion demos | PROD-AC-04 | T31 | 1440 x 1280 |
| [Motion](static/Motion.html) ([png](png/Motion.png), [source](source/Motion.dc.html)) | Brand | Six motion specs with live demos; acceptance reference for the motion pass | NAV | T39 | 1440 x 840 |
| [Sidebar](static/Sidebar.html) ([png](png/Sidebar.png), [source](source/Sidebar.dc.html)) | Component | Sidebar component used by the screens (props: dark, active) | NAV | T34 | 232 x 640 |
| [Home](static/Home.html) ([png](png/Home.png), [source](source/Home.dc.html)) | Screens | Home, Workbench layout: toolbar, four action cards, Recent, Working on, drop zone | NAV, FILE (07, 09) | T35 | 1440 x 900 |
| [Queue](static/Queue.html) ([png](png/Queue.png), [source](source/Queue.dc.html)) | Screens | Queue: Working on, Waiting, Needs attention, concurrency group | FILE (09) | T35 | 1440 x 900 |
| [Library](static/Library.html) ([png](png/Library.png), [source](source/Library.dc.html)) | Screens | Library: filter chips, table with languages and speakers, selected row | LIB (10), SCR-001 | T35 | 1440 x 900 |
| [Editor](static/Editor.html) ([png](png/Editor.png), [source](source/Editor.dc.html)) | Screens | Editor + player (dark): transcript, karaoke, inspector, floating dock | EDIT, IGN, FR, DIA (11, 17, 18, 04) | T36 | 1440 x 900 |
| [Meetings](static/Meetings.html) ([png](png/Meetings.png), [source](source/Meetings.dc.html)) | Screens | Meetings: inline detection banner, meeting rows with source and recording flags | MTG (05) | T37 | 1440 x 900 |
| [Live](static/Live.html) ([png](png/Live.png), [source](source/Live.dc.html)) | Screens | Live view: source group, Stop, volatile text, input levels | LIVE, AUD (15, 01) | T37 | 1440 x 900 |
| [Floating](static/Floating.html) ([png](png/Floating.png), [source](source/Floating.dc.html)) | Screens | Menu bar popover, live overlay, dictation HUD, meeting prompt on a wallpaper | MENU, LIVE, DICT, MTG (08, 15, 16, 05) | T37 | 1440 x 900 |
| [Settings](static/Settings.html) ([png](png/Settings.png), [source](source/Settings.dc.html)) | Screens | Settings, Models tab: disk usage, download progress, licence badge | SET, ENG (12, 02) | T38 | 1440 x 900 |
| [Onboarding](static/Onboarding.html) ([png](png/Onboarding.png), [source](source/Onboarding.dc.html)) | Screens | Onboarding step 2 in detail: languages and recommended model | ONB (13) | T38 | 1440 x 900 |
| [Export](static/Export.html) ([png](png/Export.png), [source](source/Export.dc.html)) | Screens | Export sheet: formats, options, preview | EXP (14) | T38 | 900 x 700 |
| [Flow](static/Flow.html) ([png](png/Flow.png), [source](source/Flow.dc.html)) | Coverage | Onboarding, all five steps, including just-in-time permissions and consent | ONB (13) | T38 (and T27) | 1440 x 1170 |
| [States](static/States.html) ([png](png/States.png), [source](source/States.dc.html)) | Coverage | Recently Deleted, empty states, errors, skeleton loading, inline model download | LIB, NAV-AC-07/08, PROD-AC-02 | T35 | 1440 x 1100 |
| [Components](static/Components.html) ([png](png/Components.png), [source](source/Components.dc.html)) | Coverage | Light Editor, find/replace bar, speaker popover, translation views, overlay presets | EDIT, FR, DIA, TRN, LIVE | T36, T37 | 1440 x 940 |
| [SettingsTabs](static/SettingsTabs.html) ([png](png/SettingsTabs.png), [source](source/SettingsTabs.dc.html)) | Coverage | Settings, General and Privacy and Permissions panes | SET, PERM (12) | T38 | 1440 x 820 |
| [Responsive](static/Responsive.html) ([png](png/Responsive.png), [source](source/Responsive.dc.html)) | Coverage | Narrow, compact and wide window schematics | NAV-AC-12 | T34 | 1440 x 800 |
| [Handoff1](static/Handoff1.html) ([png](png/Handoff1.png), [source](source/Handoff1.dc.html)) | Handoff | Tokens, glass materials, type scale, layout, motion tokens, SwiftUI mapping | all | T31 | 1440 x 1540 |
| [Handoff2](static/Handoff2.html) ([png](png/Handoff2.png), [source](source/Handoff2.dc.html)) | Handoff | Screen inventory, brand asset spec, caveats, coverage, kickoff gate | all | all | 1440 x 2680 |

## Regenerating the static files and PNGs

The `.dc.html` sources need the Claude Design runtime to render, which is **not** committed (it is the tool vendor's file). To regenerate: (1) with the Artifact tool, read `artifact-type/dc-runtime.js` from the canvas above and save it as `dc-runtime.js` in a scratch folder; (2) copy `source/*.dc.html` and `source/canvas.json` there, replacing `./support.js` with `./dc-runtime.js` in each source; (3) serve the folder over HTTP (`python3 -m http.server 8765`), because the sidebar component is fetched by URL; (4) `npm i playwright-core` and run `node tools/render-mockups.mjs` (set the Chromium path inside the script). The generated files in this folder were produced exactly that way and verified to render the same with JavaScript disabled.

## Authoritative values

Colours, type, spacing, glass and motion numbers: `Handoff1`. Icon and symbol geometry: `Main` and `Icons`. Screen-to-spec-to-task mapping, asset spec, caveats and coverage: `Handoff2` and `../m8-handoff.md`. Locked decisions: `../m8-ui-overhaul.md`. Mockup copy, names and numbers are placeholders.
