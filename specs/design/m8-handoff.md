# M8 Handoff: building the final Earmark design

Status: **FINAL v1 (2026-11-22)**. Read with `/specs/design/m8-ui-overhaul.md` (locked decisions) and `/specs/tasks.md` (M8, T31-T40).

## 0. Kickoff gate (do this first)
1. **Ask the user for the Claude Design canvas link.** Canonical: https://claude.ai/artifact/FzAtjj7ZdYAkp1WHPeFSVF, final v1, published version id `1795296776-319f`. It is private to the user; access must be confirmed in the session that starts M8.
2. Read it with the Artifact tool (`action: "read"`, the URL). Confirm the canvas title ends "(Final v1)" and the Handoff boards say "Final design v1".
3. Compare to the repo copy `specs/design/m8-mockups/` (open `index.html`; sources in `source/`). If they differ, stop and ask which is authoritative.
4. Do not build from memory. Boards are HTML references: values in this document and Handoff 1 are authoritative where code needs numbers; the boards are authoritative for look and layout.
5. `specs/design/m8-mockups/archive/` holds options the user rejected. Never reintroduce them.
If the canvas link is unavailable, work from the repo copy and tell the user the web canvas could not be confirmed.

## 1. What was decided (do not reopen without the user)
See `m8-ui-overhaul.md`. In short: listening-ear mark with a 28% curl, ear offset left 2.5%; fixed Ember accent `#C44B16` (`#F28A57` dark); fully custom duotone symbols; Workbench Home; glass budget of three layers per screen; Apple HIG in the app, brand freedom for marketing; calm, editorial, tasteful Liquid Glass; graceful, short motion.

## 2. Mockups: where they are and how to open them
Local copy in `specs/design/m8-mockups/`: open `index.html` (gallery). Per board there is a self-contained `static/<Board>.html` (no runtime needed), a `png/<Board>.png`, and the editable Claude Design source in `source/<Board>.dc.html`. `README.md` there has the full board index with covers and task columns, and how to regenerate. Rejected options are in `archive/`.
| Board | Purpose |
|---|---|
| `Main` | Brand identity: mark, lockups, icon light/dark/small, colour, type, voice. Authoritative icon geometry. |
| `Icons` | 24 custom symbols with asset names, construction, sizes, sidebar states. Authoritative symbol geometry. |
| `Glass`, `Motion` | Materials, glass budget, easing, live motion demos; acceptance reference for T39. |
| `Sidebar` | Sidebar component used by the screens (props `dark`, `active`). |
| `Home`, `Queue`, `Library`, `Editor`, `Meetings`, `Live`, `Floating`, `Settings`, `Onboarding`, `Export` | The core screens. Editor is dark, the rest light. |
| `Flow`, `States`, `Components`, `SettingsTabs`, `Responsive` | Coverage boards: all onboarding steps, Recently Deleted, empty/error/loading states, find/replace, speaker popover, translation views, overlay presets, light Editor, General and Privacy panes, window sizes. |
| `Handoff1`, `Handoff2` | Tokens and SwiftUI mapping; screen inventory, asset spec, caveats, coverage, kickoff gate. |
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

## 4. Implementation map onto the existing code (survey of `main` at the M2 integration)
M2 already built the shell, Home/Queue/Library, Editor, Settings and menu bar. The survey: the Features sources already use `DS*` tokens 227 times with about 5 raw literals; `GlassCard` is used twice (both in `HomeView.swift`); there are no custom symbols, no `.glassEffect` calls and no asset catalog; sidebar and toolbars are stock SwiftUI (`NavigationSplitView`, `ToolbarItem`), so they already pick up system glass; symbol names reach views mostly through model properties (`AppSection.systemImage`), 143 `systemImage:`/`systemName:` uses in total; no `accessibilityIdentifier`s yet. Consequence: M8 is a token-and-style change plus new assets, not a rewrite.
- **Extend `Packages/DesignSystem`** (`Tokens.swift`, `GlassPolicy.swift`, `Components.swift`, `SpeakerPalette.swift`, `SinhalaFont.swift`). Do not add a second design package. Keep every existing public name.
- **Token names (keep; change values and add):** `contentBackground` = Sheet, `solidChrome` = Paper, `hairline` = line, `primaryText` = ink, `secondaryText` = ink2, `accent` = Ember, `recording`, `success`, `warning`, `danger`. Add: `insetBackground`, `tertiaryText` (ink3), `accentTint`, glass and motion tokens. Today `DSColor` uses system semantic colours and `accent = Color.accentColor`; T31 sets the AccentColor asset to Ember and applies `.tint(DSColor.accent)` at the root so Ember wins over the system accent with no per-view edits.
- **Speaker palette:** the existing `SpeakerPalette` is Okabe-Ito derived with contrast tests (3:1 on light and dark surfaces). Keep that machinery and its tests. The mockup palette in section 3 is illustrative; T31 retunes entries toward it only where the contrast tests still pass, otherwise the tested palette stays.
- **`GlassCard` and `GlassPanel`** put glass on content. Replace their use on content with solid `SheetCard`/`InsetCard`; migrate the two uses in `HomeView.swift`. Keep `AccessibilityPolicy` (`usesSolidSurface`, `suppressesMotion`) as the single switch for solid fallback and Reduce Motion.
- **Sidebar:** the stock `NavigationSplitView` sidebar in `FeatureShell/ShellView.swift` stays; add a custom row style, the selection glide and the footer (folders, model chip). `AppSection.systemImage` is the symbol seam.
- **Toolbar:** `ToolbarItem`/`ToolbarItemGroup` with glass button styles; one solid Ember capsule for the primary action per view.
- **Symbols (T33):** introduce `DSSymbol` (enum plus a `Label`/`Image` helper that resolves a custom symbol asset with a stock SF Symbol fallback). Codemod only the 24 covered glyphs; generic chrome glyphs stay stock.
- **Floating surfaces:** NSPanel (non-activating, click-through overlay) with a visual effect view; menu bar popover is `FeatureMenuBar/MenuBarContentView.swift`.
- **Assets (T32):** no `.xcassets` exists. Add an asset catalog (AppIcon from Icon Composer, AccentColor, menu bar template image) and reference it in `project.yml`.
- **Fonts:** SF Pro for controls, New York (`.system(design: .serif)`) for titles and transcript, `SinhalaFont` cascade for Sinhala. Newsreader is brand-only and is not bundled.
- **Tests:** `Packages/Features/Tests/FeaturesTests/EditorRenderTests.swift` renders views with `ImageRenderer`; it checks content, so expect snapshot-style additions rather than rewrites. Add `accessibilityIdentifier`s before M8 (plan rule A6) so UI tests survive the restyle.
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
- **T32.** The app icon matches the `Main` board geometry, ear offset left 2.5%, curl 28%, legible at 16 px; Default, Dark, Tinted, Clear render. Menu bar glyph shows idle and recording states.
- **T33.** Every symbol in the `Icons` board exists with its asset name in 9 weight/scale variants; a side-by-side check against SF Symbols at each weight passes review; every symbol has an accessibility label where used standalone; fallbacks map to stock symbols.
- **T34.** Each screen shows at most three glass layers (UI test counts glass modifiers). ⌘1-⌘6 select sections. Selection pill glides (200-280 ms) and honours Reduce Motion.
- **T35-T38.** Each screen matches its artboard at 1440 x 900 in the appearance drawn and in the other; screenshots attached to the PR. Derived screens (see Handoff 2, "Not drawn yet") follow the stated rules and are reviewed by the HIG reviewer.
- **T39.** Every motion in the `Motion` board is implemented with the stated curve and time; Reduce Motion variants are crossfades; the recording pulse is the only infinite animation besides skeleton shimmer.
- **T40.** All token pairs meet 4.5:1 (3:1 at 24 pt and above) in both appearances and Increase Contrast; VoiceOver labels on every control; Dynamic Type largest size reflows without clipping; T28 performance targets and T30 XCUITests still pass; glass layers cost profiled on M1-class hardware with no scroll hitches (16 ms frame budget).

## 8. Caveats and open items
| Caveat | Status |
|---|---|
| Boards use web fonts and approximate glyphs | Resolved: real fonts specified; geometry in `Icons`/`Main` authoritative; T33 redraws on the SF Symbols template. |
| Custom duotone is the least native symbol choice | Accepted by the user; scope is the 24 covered glyphs plus the ear, generic chrome glyphs stay stock; T33 review gate and stock fallbacks. |
| Glass API names are unverified | Open: T31 spike. |
| Contrast checked by calculation, not in a built app | Open: T40. Dark values for recording/success/danger and the extra speaker colours are specified here and also need T40 verification. |
| Speaker palette in the boards differs from the tested `SpeakerPalette` | Resolved: tested palette stays authoritative; retune only where contrast tests pass (section 4). |
| Previously "not drawn" screens and states | Resolved: drawn in `Flow`, `States`, `Components`, `SettingsTabs`, `Responsive`. Residual, derived by rule: light/dark of screens drawn in one appearance (swap tokens), Library grid view (reuse Home Recent cards), Dock badge (recording red). |
| Settings tabs not drawn individually (Audio, Languages, Meetings, Export) | Derived: same Sheet rows, one hairline, native controls tinted Ember (pattern in `Settings`, `SettingsTabs`). |
| Boards are 1440 x 900 | Resolved: `Responsive` and section 5 give the window-size rules. |
| Copy, names, durations and quotes are placeholders | Real strings from feature specs and localisation. |
| Static HTML needs Google Fonts online for Newsreader/Noto Sans Sinhala | Offline fallbacks apply; not a build dependency. |
## 9. Provenance
Decisions were made in a gated session: mark B (listening ear), then fold on the squircle (28% curl), ear offset (B, left 2.5%, chosen over left 4%), brand colour (Ember, from five options), glass budget (reduced after the user judged the first pass over-glassed), symbols (C, fully custom duotone), Home layout (B Workbench). Rejected exploration boards are in `m8-mockups/archive/`.
