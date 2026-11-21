# M8 Handoff: building the final Earmark design

Status: **FINAL v1 (2026-11-22)**. Read with `/specs/design/m8-ui-overhaul.md` (locked decisions) and `/specs/tasks.md` (M8, T31-T40).

## 0. Kickoff gate (do this first)
1. **Ask the user for the Claude Design canvas link.** Canonical: https://claude.ai/artifact/FzAtjj7ZdYAkp1WHPeFSVF, final v1, published version id `1795296177-4e67`. It is private to the user; access must be confirmed in the session that starts M8.
2. Read it with the Artifact tool (`action: "read"`, the URL). Confirm the canvas title ends "(Final v1)" and the Handoff boards say "Final design v1".
3. Compare to the repo copy `specs/design/m8-mockups/*.dc.html`. If they differ, stop and ask which is authoritative.
4. Do not build from memory. Boards are HTML references: values in this document and Handoff 1 are authoritative where code needs numbers; the boards are authoritative for look and layout.
5. `specs/design/m8-mockups/archive/` holds options the user rejected. Never reintroduce them.
If the canvas link is unavailable, work from the repo copy and tell the user the web canvas could not be confirmed.

## 1. What was decided (do not reopen without the user)
See `m8-ui-overhaul.md`. In short: listening-ear mark with a 28% curl, ear offset left 2.5%; fixed Ember accent `#C44B16` (`#F28A57` dark); fully custom duotone symbols; Workbench Home; glass budget of three layers per screen; Apple HIG in the app, brand freedom for marketing; calm, editorial, tasteful Liquid Glass; graceful, short motion.

## 2. Board index (canvas and repo)
| Board file | Purpose |
|---|---|
| `Main.dc.html` | Brand identity: mark, lockups, icon light/dark/small, colour, type, voice. Authoritative icon geometry. |
| `Icons.dc.html` | 24 custom symbols with asset names, construction, sizes, sidebar states. Authoritative symbol geometry. |
| `Glass.dc.html` | Materials (Clear, Regular, Prominent, solid twin), shape, glass budget, easing, motion demos. |
| `Motion.dc.html` | Six motion specs with live demos; acceptance reference for T39. |
| `Sidebar.dc.html` | Sidebar component used by the screens (props: `dark`, `active`). |
| `Home`, `Queue`, `Library`, `Editor`, `Meetings`, `Live`, `Floating`, `Settings`, `Onboarding`, `Export` | The screens. Editor is dark, the rest light. |
| `Handoff1.dc.html`, `Handoff2.dc.html` | Tokens, SwiftUI mapping, screen inventory, brand asset spec, caveats, gaps. |
| `canvas.json` | Canvas layout and titles. |

## 3. Tokens
Authoritative values are in Handoff 1 (colour, glass, type, layout, motion) and reproduced here for code review.
| Token | Light | Dark |
|---|---|---|
| paper | `#F3EEE5` | `#12110F` |
| sheet | `#FCFAF6` | `#1B1A17` |
| inset | `#F7F3EB` | `#22211D` |
| ink / ink2 / ink3 | `#1C1B18` / `#5A564E` / `#6B675D` | `#F3EFE7` / `#B5B0A5` / `#9A9589` |
| ember | `#C44B16` (4.8:1 on white) | `#F28A57` |
| emberTint | `#F7E4D8` | `rgba(242,138,87,.16)` |
| recording | `#D1352B` | `#FF6B5E` |
| success / danger | `#2F7A4F` / `#B3321F` | `#6CC48F` / `#FF8A7A` |
| speakers | `#C44B16 #1B7A74 #5558D6 #A67A0B #9A3E7A #5B6B7A` | `#F28A57 #4FB3AB #8E8CF0 #E0B04A` plus two more matched in lightness |
Dark values for recording, success, danger and the last two speakers were specified in this handoff and need T40 contrast verification.

## 4. Implementation map onto the existing code
- Extend `Packages/DesignSystem` (Tokens.swift, GlassPolicy.swift, Components.swift, SpeakerPalette.swift, SinhalaFont.swift). Do not add a second design package.
- `GlassCard` and `GlassPanel` currently put glass on content. Under the budget they must become solid `SheetCard` / `InsetCard`; glass is limited to the sidebar, one toolbar group and one transient floater. Keep `AccessibilityPolicy` as the single switch for solid fallback and Reduce Motion.
- Sidebar: `NavigationSplitView` sidebar (system material) with custom row style; never hand-roll blur for it.
- Toolbar: `ToolbarItemGroup` with glass button style; no full-width glass bar. One solid Ember capsule for the primary action per view.
- Floating surfaces: NSPanel (non-activating, click-through overlay) with system visual effect; popover via `MenuBarExtra` window style.
- Fonts: SF Pro for controls, New York (`.system(design: .serif)`) for titles and transcript, `SinhalaFont` cascade for Sinhala. Newsreader is brand-only and is not bundled.
- App icon via Icon Composer; menu bar glyph as a template image.
- Glass API names in section 6 are intent; T31 confirms the real API in the SDK in use and records it in `m8-spike.md`.

## 5. Behaviour rules the boards imply
- One primary action per view, solid Ember. Destructive and recording use their own colours, never Ember.
- Recording is always visible (menu bar, Live toolbar, overlay); the pulse stops under Reduce Motion but the dot stays.
- Lists use skeletons while loading; new items arrive in place with an Ember tint that fades; nothing reflows under the cursor.
- Errors are inline banners on a danger tint with Retry; permission denial links to System Settings. Never a blocking modal for a failed job.
- Transcript, tables and settings never sit on glass.
- Window minimum 960 x 600. Below 1100 pt hide the Editor inspector behind a toolbar toggle; below 800 pt collapse the sidebar. Content max width 1120 pt, centred.
- Sinhala must shape correctly at every size and in every surface including overlay and exports' previews.

## 6. Glass mapping (intent, verify in T31)
| Layer | Boards | SwiftUI direction |
|---|---|---|
| Clear | blur 16, fill 30% | `.glassEffect(.clear, in:)` for small pills over media |
| Regular | blur 28, fill 58% | `.glassEffect(.regular, in:)`, sidebar via NavigationSplitView, toolbar groups with glass button style, wrapped in `GlassEffectContainer` |
| Prominent | blur 40, fill 72-82% | Regular plus stronger tint, or NSPanel + NSVisualEffectView for overlay, HUD, prompts |
| Solid twin | opaque sheet, stronger hairline | when `AccessibilityPolicy.usesSolidSurface` |

## 7. Acceptance criteria per task (in addition to the global Definition of Done)
- **T31.** WHEN any view renders in light or dark THE SYSTEM SHALL use only DesignSystem tokens (no literal hex in app views). WHEN Reduce Transparency or Increase Contrast is on THE SYSTEM SHALL render every glass layer as its solid twin. A lint or test fails the build if a view applies glass to content (cards, lists, inspector). `m8-spike.md` exists with findings on glass API names, symbol weight matching, Icon Composer.
- **T32.** The app icon matches `Main.dc.html` geometry, ear offset left 2.5%, curl 28%, legible at 16 px; Default, Dark, Tinted, Clear render. Menu bar glyph shows idle and recording states.
- **T33.** Every symbol in `Icons.dc.html` exists with its asset name in 9 weight/scale variants; a side-by-side check against SF Symbols at each weight passes review; every symbol has an accessibility label where used standalone; fallbacks map to stock symbols.
- **T34.** Each screen shows at most three glass layers (UI test counts glass modifiers). ⌘1-⌘6 select sections. Selection pill glides (200-280 ms) and honours Reduce Motion.
- **T35-T38.** Each screen matches its artboard at 1440 x 900 in the appearance drawn and in the other; screenshots attached to the PR. Derived screens (see Handoff 2, "Not drawn yet") follow the stated rules and are reviewed by the HIG reviewer.
- **T39.** Every motion in `Motion.dc.html` is implemented with the stated curve and time; Reduce Motion variants are crossfades; the recording pulse is the only infinite animation besides skeleton shimmer.
- **T40.** All token pairs meet 4.5:1 (3:1 at 24 pt and above) in both appearances and Increase Contrast; VoiceOver labels on every control; Dynamic Type largest size reflows without clipping; T28 performance targets and T30 XCUITests still pass; glass layers cost profiled on M1-class hardware with no scroll hitches (16 ms frame budget).

## 8. Caveats and open items
| Caveat | Status |
|---|---|
| Boards use web fonts and approximate glyphs | Resolved: real fonts specified; geometry in `Icons.dc.html` authoritative; T33 redraws on the SF Symbols template. |
| Custom duotone is the least native symbol choice | Accepted by the user; mitigated by the T33 review gate and stock fallbacks. |
| Glass API names are unverified | Open: T31 spike. |
| Contrast checked by calculation, not in a built app | Open: T40. |
| Dark values for status colours and extra speakers | Open: verify in T31/T40. |
| Not drawn: onboarding steps 1, 3, 4, 5; Recently Deleted; empty and error states; other Settings tabs; find/replace; speaker editing; translation views; overlay presets; light Editor; narrow/wide windows | Derive from the rules in Handoff 2 "Not drawn yet"; HIG reviewer signs off. |
| Boards show 1440 x 900 only | Responsive rules in section 5. |
| Copy, names, durations and quotes are placeholders | Real strings from feature specs and localisation. |

## 9. Provenance
Decisions were made in a gated session: mark B (listening ear), then fold on the squircle (28% curl), ear offset (B, left 2.5%, chosen over left 4%), brand colour (Ember, from five options), glass budget (reduced after the user judged the first pass over-glassed), symbols (C, fully custom duotone), Home layout (B Workbench). Rejected exploration boards are in `m8-mockups/archive/`.
