# M8 spike (T31): Liquid Glass APIs, SF Symbols custom symbols, Icon Composer

Status: **written 2026-11-22 by T31**. Toolchain verified: Xcode 27.2 (27B52), Swift 6.4.2, `MacOSX27.2.sdk`, host macOS 27.2, project deployment target **macOS 26.0**. Everything below was read from the installed SDK (`.swiftinterface`, AppKit headers) or executed (`actool`, `assetutil`, `ictool`). Items marked **UNVERIFIED** were not observed on a running system.

## 1. SwiftUI Liquid Glass APIs (real names, from `SwiftUICore`/`SwiftUI` interfaces)

All are `@available(iOS 26, macOS 26, tvOS 26, watchOS 26, *)` and `visionOS unavailable`, unless noted. **Because our deployment target is macOS 26.0, no `#available` guard is needed (or allowed: under warnings-as-errors an `if #available(macOS 26, *)` is an "unnecessary check" error).** The DesignSystem wrapper is therefore a plain modifier; the `#available` guard is only meaningful for macOS 27-only API (see `NSGlassEffectView.effectIsInteractive` below).

| API | Signature / notes |
|---|---|
| `View.glassEffect(_:in:)` | `func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View`. Default shape is a capsule. |
| `Glass` | `struct Glass: Equatable, Sendable`; `static var regular`, `static var clear`, `static var identity`; `func tint(_ color: Color?) -> Glass`; `func interactive(_ isEnabled: Bool = true) -> Glass`. **There is no `.prominent`**; the board's Prominent layer is `.regular.tint(...)` (SwiftUI) or `NSGlassEffectView` with tint (panels). |
| `GlassEffectContainer` | `GlassEffectContainer(spacing: CGFloat? = nil) { content }`. Merges nearby glass shapes (morphing, one render pass). Wrap adjacent glass in one container. |
| `glassEffectID(_:in:)` | `func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID)`. Morphing transitions between glass shapes inside one container. |
| `glassEffectUnion(id:namespace:)` | `func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID)`. Merges several views into one glass shape. |
| `glassEffectTransition(_:)` | `GlassEffectTransition`: `.matchedGeometry`, `.materialize`, `.identity`. |
| Button styles | `.buttonStyle(.glass)` (`GlassButtonStyle`) and `.glass(_ glass: Glass)`; `.buttonStyle(.glassProminent)` (`GlassProminentButtonStyle`, uses the tint). |
| `backgroundExtensionEffect()` | `View.backgroundExtensionEffect()` / `(isEnabled:)`, macOS 26 (also visionOS). Mirrors and blurs content past the safe area. Use for a hero/artwork edge under the floating sidebar/toolbar; **never needed for the transcript** (solid sheet). |
| Scroll edge effects | `scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for: Edge.Set)` with `.automatic`, `.hard`, `.soft`; `scrollEdgeEffectHidden(_:for:)`. macOS 26. On macOS prefer `.hard` under toolbars over text-dense lists. |
| Toolbar | `ToolbarSpacer(_ sizing: SpacerSizing = .flexible, placement:)` (separates glass groups in the toolbar); `ToolbarContent.sharedBackgroundVisibility(_:)` (`.hidden` removes the shared glass capsule behind an item). Toolbar items on macOS 26 get system glass automatically; **do not add our own glass to toolbar items**, group with `ToolbarItemGroup` and `ToolbarSpacer`. |
| `NSGlassEffectView` / `NSGlassEffectContainerView` | AppKit, `API_AVAILABLE(macos(26.0))`. `contentView`, `cornerRadius`, `tintColor: NSColor?`, `style: .regular / .clear`. **`effectIsInteractive` is macOS 27.0 only** (needs `#available(macOS 27, *)`). Container: `contentView`, `spacing`. Apple warns arbitrary subviews of `NSGlassEffectView` are not guaranteed z-order: always put content in `contentView`. |
| `NSBackgroundExtensionView` | AppKit macOS 26, `contentView` extended to fill. |
| `NSBezelStyleGlass` | `NSButton.BezelStyle.glass` (raw 16), macOS 26. |

### NSPanel overlays (live captions, dictation HUD, meeting prompt)
- Preferred for a borderless non-activating `NSPanel` hosting SwiftUI: keep the SwiftUI content with `.glassEffect(...)` (our `dsGlass`); the SwiftUI glass renders inside the hosting view and needs a clear panel background (`isOpaque = false`, `backgroundColor = .clear`, `hasShadow` as designed).
- Use `NSGlassEffectView` (set `contentView` to an `NSHostingView`, `cornerRadius`, `tintColor`, `style`) only when the panel must be AppKit-first or you need the AppKit tint/style properties. `NSVisualEffectView` still exists (materials) and is the fallback for the Prominent layer; it does not give the Liquid Glass lensing.
- Never nest glass in glass: do not put `.glassEffect` content inside an `NSGlassEffectView`.

### Our wrapper decisions (DesignSystem v2)
- `DSGlassLayer` = `.clear` (`Glass.clear`), `.regular` (`Glass.regular`), `.prominent` (`Glass.regular.tint(DSColor.paper.opacity(0.55))`).
- `View.dsGlass(_ layer:, in:, tint:, interactive:)`: system glass, or the **solid twin** (Sheet fill, 1 px `hairlineStrong`, same shape) when `AccessibilityPolicy.usesSolidSurface`. `glassBackground(radius:tint:interactive:)` is kept and forwards to `dsGlass(.regular)`.
- Budget: max 3 layers per screen (sidebar, one toolbar group, one transient floater). Enforced by a source guard test (`DesignGuardTests`): glass APIs outside DesignSystem require a `// glass-layer: sidebar|toolbar|floater` marker in the file; `GlassCard`/`GlassPanel` are banned in Features.

### Reduce Transparency / Increase Contrast
- System behaviour (documented by Apple, **UNVERIFIED by observation here: we did not toggle the user's accessibility settings**): with Reduce Transparency system glass frosts to a more opaque material; Increase Contrast adds borders and darker/lighter fills. SwiftUI's `glassEffect` follows both automatically.
- We do not rely on that. Our own twin is driven by `AccessibilityPolicy` (`accessibilityReduceTransparency` OR `colorSchemeContrast == .increased` -> `usesSolidSurface`), so the twin is deterministic and testable, and contrast of every token pair is computed in tests. Stock toolbar/sidebar glass is left to the system.

## 2. SF Symbols custom symbols (T33 input)

Verified with `actool` + `assetutil` (Xcode 27.2):
- A custom symbol in an asset catalog is a `NAME.symbolset/` folder with `Contents.json` `{"info":{"author":"xcode","version":1},"symbols":[{"filename":"NAME.svg","idiom":"universal"}]}` and the SVG exported from the SF Symbols app ("Export Template" / custom symbol). The template is SVG 3.0: groups `Notes`, `Guides` (`Baseline-S/M/L`, `Capline-S/M/L` lines) and `Symbols` with one `<g id="Weight-Size">` per master, e.g. `Regular-S`, `Ultralight-S`, `Black-S`.
- **actool requires the Regular weight in all three sizes** (`Regular-S`, `Regular-M`, `Regular-L`) and the Baseline/Capline guides for each size; otherwise it fails: `must have a glyph for Regular weight Medium size`, `missing a baseline guide for Baseline-M`.
- `Ultralight-S` and `Black-S` are accepted as optional masters. The compiled `Assets.car` showed "Vector Glyph" renditions for Ultralight, Regular, Black and Small/Medium/Large glyph sizes. The nine weights (Ultralight, Thin, Light, Regular, Medium, Semibold, Bold, Heavy, Black) are interpolated by the system from the Ultralight, Regular and Black masters; **design all three masters with compatible point structure** (same number and order of points) or interpolation breaks. Scales: small, medium, large (3), each its own master group.
- Layer annotations (Annotations in the SF Symbols app, written into the SVG classes): `monochrome-0..n`, `hierarchical-0:primary/secondary/tertiary`, `multicolor-0:tintColor|systemRedColor|...`. Palette rendering (`.symbolRenderingMode(.palette)`) uses the layer indices: for the duotone set, layer 0 = ink line, layer 1 = the single Ember detail. Reference palettes in code with `.foregroundStyle(ink, ember)`.
- Loading: `Image("lk.name")` resolves from the app bundle catalog; in a Swift package use `Image("name", bundle: .module)` (requires the catalog or `.symbolset` in the package resources). `Image(systemName:)` does not find custom symbols. Weight/scale follow `.font(...)` / `.fontWeight(...)` / `.imageScale(...)` like stock symbols (this is the "weight-matching with system text" mechanism).
- SF Symbols app is not installed on this Mac (`/Applications` has none), so authoring/export of the real 24-symbol set must be done in the SF Symbols app from the `Icons` board geometry; T33 decides whether to author SVGs programmatically (the minimal template above compiles) or by hand.
- **UNVERIFIED**: visual weight-match against system text at each weight; needs T33's side-by-side gate.

## 3. Icon Composer `.icon` format (T32 input)

Icon Composer ships inside Xcode: `Xcode.app/Contents/Applications/Icon Composer.app` with CLI `Contents/Executables/ictool` (v27.2, bundle 143). A `.icon` is a **directory bundle** that can be written by hand:

```
AppIcon.icon/
  icon.json
  Assets/ear.svg          (layers referenced by image-name; SVG or PNG)
```
Verified minimal `icon.json` (compiled by `actool` and rendered by `ictool`; Default and Dark renditions both rendered correctly, the dark fill specialization was honoured):
```json
{
  "fill": { "solid": "display-p3:0.76863,0.29412,0.08627,1.00000" },
  "fill-specializations": [
    { "appearance": "dark", "value": { "solid": "display-p3:0.07059,0.06667,0.05882,1.00000" } }
  ],
  "groups": [
    { "layers": [ { "name": "ear", "image-name": "ear.svg", "glass": true } ],
      "shadow": { "kind": "neutral", "opacity": 0.5 },
      "translucency": { "enabled": true, "value": 0.4 } }
  ],
  "supported-platforms": { "squares": "shared" }
}
```
Other keys seen in the Icon Composer framework (names only; semantics not exercised): `fill` also takes `automatic-gradient` and `linear-gradient`; per-layer/group `opacity`, `hidden`, `blend-mode`, `blur-material`, `lighting`, `specular`, `position` (`scale`, `translation-in-points`) and their `-specializations` arrays (appearance `dark`, idiom, etc.); `supported-platforms` accepts `squares` (`"shared"` or a platform list) and `circles`.
- Compile: `xcrun actool Foo.icon --compile OUT --platform macosx --minimum-deployment-target 26.0 --app-icon Foo --output-partial-info-plist OUT/partial.plist` produced `Assets.car` (1.5 MB, with the layered icon), `Foo.icns` (fallback) and a partial plist with `CFBundleIconFile`/`CFBundleIconName`. In an Xcode project a `.icon` file in the target's resources is compiled by the same actool step (`ASSETCATALOG_COMPILER_APPICON_NAME` = icon name). XcodeGen: add the `.icon` as a resource/source of the app target (T32; project.yml is not touched by T31).
- Preview: `ictool Foo.icon --export-image --output-file out.png --platform macOS --rendition Default|Dark|TintedLight|TintedDark|ClearLight|ClearDark --width W --height H --scale S [--tint-color --tint-strength] [--design-generation 26|27]`. (Renditions Default and Dark executed here; the others are from the CLI usage text.) The system applies the Liquid Glass specular/shading, so bake no gloss (matches the locked decision).
- Gotcha: a single white layer on a dark fill was auto-tinted by Icon Composer in the Dark rendition (the layer rendered in the Ember colour); specify dark behaviour explicitly via `*-specializations` and check each rendition.

## 4. Other facts and decisions
- SwiftUI `Font.system(_:design:)` with `.serif` gives New York. `NSFont(name: "New York")` is not reliable; build serif NSFonts via `fontDescriptor.withDesign(.serif)` and then add the Sinhala cascade (done in `SinhalaFont.serifNSFont`).
- Tabular numerals: `.monospacedDigit()` on the font.
- `Animation.timingCurve(.2, .9, .3, 1.1, duration:)` supports control points beyond 1.0 (settle overshoot). Reduce Motion cannot be a bare `nil` for moving content: `DSMotion` returns a 120 ms linear animation and `DSTransition.settle/glide/exit` become `.opacity`. `AccessibilityPolicy.animation(_:)` (nil under Reduce Motion) is unchanged.
- Root tint: `.tint(DSColor.accent)` on each scene's root (Ember is a fixed brand colour; AccentColor asset belongs to T32). SwiftUI controls and the sidebar selection then follow Ember; `NSColor.controlAccentColor` based AppKit controls still follow the system accent until T32 adds the asset.
- DesignSystem v2 outcome (observed in a launched Debug build, dark): `.tint(DSColor.accent)` at the scene roots makes SwiftUI controls (Download button) Ember, but the stock sidebar selection pill and icons stay system blue; they follow `NSColor.controlAccentColor` and are fixed by the `AccentColor` asset (T32) or T34's custom sidebar rows.
- SpeakerPalette: slots 0-5 are the board palette, slots 6-7 keep the tested blue and crimson (count stays 8). Speaker colours persisted as hex from the old palette no longer match a slot and render as fixed (non-adaptive) colours; acceptable pre-release.
- Guard tests: `Packages/Features/Tests/FeaturesTests/DesignGuardTests.swift` (GlassCard/GlassPanel banned, glass APIs need a `// glass-layer: sidebar|toolbar|floater` marker, no literal colours; allowlist `WordFlow.swift`, `PreferenceViews.swift` for user-chosen colours). Panels outside Features (LiveCaptions overlay, Dictation HUD) are not scanned.
- Chosen at T31 (not in boards): `warning` #8F5300 / #E8A93C, `lineStrong`, dark speaker colours #E58AC0 and #9DB0C2.
- Contrast results of the locked tokens (computed, see `DSContrastTests`): ember on sheet 4.61:1, on inset 4.35, on paper 4.16, on emberTint 3.90; recording on paper 4.27, inset 4.46. These are below 4.5:1 for small text; they are recorded as known exceptions (use at >= 14 pt bold or as non-text 3:1) and reported to T40. The locked hexes are not changed.
