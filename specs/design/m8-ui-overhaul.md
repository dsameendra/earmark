# M8 UI/UX Overhaul and Visual Identity: locked decisions

Status: **DESIGN LOCKED (2026-11-22)**, implementation scheduled as the last milestone (T31-T40 in `/specs/tasks.md`).
Canvas: https://claude.ai/artifact/FzAtjj7ZdYAkp1WHPeFSVF (final v1, version id `1795296776-319f`). Local copy: `/specs/design/m8-mockups/` (`index.html` gallery, `static/` HTML snapshots, `png/` previews, `source/` Claude Design sources). Rejected options: `/specs/design/m8-mockups/archive/`. How to build it, acceptance criteria and open items: `/specs/design/m8-handoff.md`. **M8 must start with the kickoff gate in that document (ask the user for the canvas link).**

## Governing rule
Earmark is a macOS 26 app: Apple HIG applies to every in-app surface. Brand and marketing pieces may use brand fonts and custom artwork.

## Approved real-app refinements
The owner's 2026-11-22 review supersedes the global workspace width cap and Settings toolbar tabs: workspace surfaces fill the detail column, while Settings uses grouped vertical navigation. Onboarding has no titlebar strip or Window-menu entry; its brand panel fills the window edge. Sinhala is presented alongside other languages. Search, Find and Replace have distinct symbols. See [SCR-007](../changes/SCR-007-cohesive-ui-refinement.md) and the [refinement QA record](../qa/ui-refinement-2026-11-22.md). The remaining visual tokens and final-v1 boards stay authoritative.

## Locked decisions
| Area | Decision |
|---|---|
| Mark | Option B "listening ear": one continuous ear line plus a single sound arc. |
| App icon | Full macOS squircle, Ember gradient, folded-corner curl in the top-right (28% of the tile), ear offset left 2.5% of tile width to balance the curl. Delivered as Icon Composer layers (squircle, ear, arc, curl). No baked gloss; the system applies Liquid Glass lighting. Dark variant: night tile, cream ear, Ember-night arc and curl. |
| Brand colour | Fixed Ember accent `#C44B16` (4.8:1 on white), Ember night `#F28A57`. It does not follow the system accent. Paper `#F3EEE5`, Sheet `#FCFAF6`, Ink `#1C1B18`, Night `#12110F`. Recording red `#D1352B` and success green `#2F7A4F` are separate from Ember. Speaker palette: `#C44B16 #1B7A74 #5558D6 #A67A0B #9A3E7A #5B6B7A` (night: `#F28A57 #4FB3AB #8E8CF0 #E0B04A`). |
| Type | In-app: SF Pro (controls) and New York (titles, transcript voice); Sinhala via the system Sinhala font cascade. Brand/marketing: Newsreader. Timestamps use tabular numerals. |
| Symbols | Fully custom duotone set (ink line plus one Ember detail), built on the SF Symbols template with matched weights and scales, palette rendering, and stock SF Symbol fallbacks. Risk noted: least native option; T33 must prove weight-matching against system text in toolbars and menus. |
| Layout | Home uses the "Workbench" layout (quick-action cards, Recent, Working on). |
| Glass | Budget of three glass layers per screen at most: (1) sidebar, (2) one floating toolbar control group (never a full-width bar), (3) one transient floater (player dock, live overlay, HUD, prompt, popover). Cards, inspectors, lists, settings and transcripts are solid in two tiers (sheet, inset). No glass on glass. Reduce Transparency swaps each glass layer for its solid twin. |
| Motion | Settle (`cubic-bezier(.2,.9,.3,1.1)`, 320-500 ms) for arrivals, glide (`cubic-bezier(.4,0,.2,1)`, 200-280 ms) for state changes, exit (`cubic-bezier(.4,0,1,1)`, 140 ms). Motion explains cause and effect, then rests. Reduce Motion: 120 ms crossfade, no pulses (the recording dot stays). |
| Controls | macOS 26 sizing: 28 pt minimum control height in the app (mockups use 32-40 pt capsules), concentric radii, capsule buttons, prominent Ember button for the single primary action per view. |

## Screens covered by the mockups
Brand identity, icon set, glass, motion, sidebar, Home (Workbench), Queue, Library, Editor + player (dark), Meetings, Live, floating surfaces (menu bar popover, live overlay, dictation HUD, meeting prompt), Settings (Models, General, Privacy), Onboarding (all five steps), Export sheet, States (Recently Deleted, empty, error, loading), Components (find/replace, speaker popover, translation views, overlay presets, light Editor), Responsive windows, and two handoff boards.

## Notes for implementers
- Mockups use web fonts as stand-ins; build with the real system fonts (see handoff).
- Authoritative icon and symbol geometry is in the `Main` and `Icons` boards in `m8-mockups/`.
- Copy in mockups is illustrative; real strings come from the feature specs.
