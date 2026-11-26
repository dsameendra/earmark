# Earmark: working rules and learnings

Read this first in every session. It records decisions the owner has made and lessons learned the hard way.

## Product guardrails (non-negotiable)
- 100% local macOS 26+ app, Apple silicon. No cloud ASR or translation, no telemetry, no analytics. The network is used only for model downloads the user starts and for Sparkle update checks the user opts into (HTTPS only).
- Swift 6 strict concurrency, warnings as errors. Apple HIG and Liquid Glass; design rules A1-A8 at the top of `specs/tasks.md`; DesignSystem tokens only (no literal colours or fixed fonts in features); at most three glass layers per screen.
- Contracts live in `AppCore` and are frozen. Changes go through a numbered change request in `specs/changes/SCR-NNN-*.md` (next free number).
- Every interactive control gets an `accessibilityIdentifier`. Reduce Motion, Reduce Transparency and Increase Contrast must keep working.

## Release rules
- **Artefact naming (owner's choice):** `Earmark-<marketing version>.dmg`, checksum `Earmark-<version>.dmg.sha256`, `appcast.xml`, git tag `v<version>`, release title `Earmark <version>`. No build number and no signing-mode suffix in the filename. Local previews are `Earmark-<version>-local.dmg` and are never published.
- The appcast enclosure URL must end with the exact published asset name. If an asset is renamed on GitHub, re-upload `appcast.xml` with the new URL (`scripts/verify-appcast.py` enforces the match). The EdDSA signature covers file bytes, not the name.
- Distribution is **self-signed, not notarized** (no paid Apple account). Users approve the first launch (Open Anyway or `xattr -dr com.apple.quarantine`). Releases are published as normal releases, not pre-releases, otherwise `releases/latest` (website button and update feed) 404s.
- Signing identity: "Earmark Release Signing" in the login Keychain. Sparkle key: account `earmark` (the default Sparkle account belongs to Downer, never use it). Backups live in `~/Developer/earmark-keys` (p12 + passphrase + Sparkle private key + public key). Never commit keys; never regenerate them (the designated requirement and the update chain depend on them).
- Recipe: bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (monotonic) in `project.yml`, commit, then
  `EARMARK_SIGN_IDENTITY='Earmark Release Signing' EARMARK_UPDATE_FEED_URL=https://github.com/dsameendra/earmark/releases/latest/download/appcast.xml EARMARK_SPARKLE_PUBLIC_KEY=<public key> scripts/release.sh selfsigned`, then `scripts/make-appcast.sh appcast <release dir>` (set `EARMARK_PREVIOUS_APPCAST` to keep older items), then `gh release create v<version> <dmg> <sha256> appcast.xml --latest`. Verify the published feed and checksum afterwards. Details: `specs/qa/release.md`.
- Before any release run the unit tests per package with `swift test --no-parallel`, the UI tests (installed Earmark closed), and prove the update path: an older copy pointed at a local HTTPS feed (temporary trusted certificate, remove it afterwards) must find, install and relaunch the new version.
- Publishing, pushing tags and changing repository settings are outward-facing: confirm with the owner first unless they have said to proceed.

## Repository workflow
- `main` is protected: changes arrive by pull request with passing checks. The owner bypasses as repository admin. Other contributors use PRs.
- The git directory lives outside iCloud at `~/Developer/earmark.git` (`.git` in the working copy is a gitfile). Never move it back into iCloud-synced folders.
- Agent worktrees under `.claude/worktrees` cost about 3 GB each: delete them after merging.

## CI (GitHub Actions)
- `static` (Linux, required for PRs): dependency boundaries, release-script tests (the `release.sh` tests are macOS-only), website validation (`scripts/check-site.py`), shell syntax, no key material. `build-and-test (macOS)`: Debug build and all package unit tests on the hosted macOS 26 image. It is green and should be made required once it has stayed green for a while (remove `continue-on-error` in `ci.yml`, then add the check to the ruleset). `CodeQL` runs for Actions and Python (Swift needs a runner with the project toolchain). `Website` deploys `docs/` to GitHub Pages on every push to `main`. `Verify release` checks a published release's appcast, checksum, names and version.
- The hosted runner has macOS 26.x with Xcode 26.x (Swift 6.3), the real minimum target, while local development uses Xcode 27 (Swift 6.4). **Code must compile with both.** Fence macOS 27-only SDK symbols with `#if compiler(>=6.4)` plus `#available`; use `@preconcurrency import AVFoundation` where Sendable diagnostics differ; split long arithmetic or ternary expressions (Swift 6.3 reports "unable to type-check in reasonable time", including inside `#expect`); do not put a `ForEach` of `ToolbarItem`s in a toolbar builder; CI builds with `SWIFT_ENABLE_EXPLICIT_MODULES=NO` (a libzstd module configuration error otherwise).
- Tests that need real hardware, local models or fixtures must skip themselves (`.enabled(if:)`) so they do not fail on virtual CI machines (for example the Apple Speech checks).
- `scripts/check.sh` prints compiler errors and failing test names on failure; use that output, it is what CI shows too.
- `main` ruleset: PR required, `static` required, no force pushes or deletions, owner bypasses as repository admin; release tags `v*` cannot be moved or deleted. Secret scanning with push protection and Dependabot are on; major `dmgbuild` bumps are ignored on purpose.

## Learnings (environment and testing)
- **iCloud evicts files** from `~/Documents` under disk pressure. Symptoms: git "packfile too short", SwiftPM hangs on git checks, Python hangs on stale `__pycache__`, fixtures read as 0 bytes. Fixes: keep git outside iCloud, delete stale `__pycache__` and a package's `.build/out`, re-download corrupt local fixtures. If SwiftPM shows `ld: no object files specified`, delete that package's `.build/out`.
- Run package tests with `--no-parallel`; heavy suites (voice enhancer, Whisper) starve the timing tests (`MicrophoneSourceTests`, seek latency) when run in parallel. The Whisper language-ID test needs intact local Sinhala fixtures.
- UI tests (`scripts/check.sh ui`, or one test via xcodebuild `-only-testing`) fail or flake if the installed Earmark is open (second menu-bar item, overlapping windows). Close it first. Exported attachments (`xcrun xcresulttool export attachments`) give real window screenshots for visual review; use them, do not guess layouts.
- SwiftUI traps found here: toolbar closures are not observation-tracked, so put dynamic toolbar controls in their own `View` (the Meetings policy menus stayed on "Ask first" until they were); a `ToolbarItem` hover highlight hugs the label unless the label has its own min height and padding (`DSToolbarLabel`); an overlay positioned by absolute offsets must be pinned top-leading at full size or the parent re-centres it (waveform hover bug); the system segmented control draws a short pill in large toolbars (use `DSSegmentedControl`); `.toolbar(removing: .sidebarToggle)` is not reliable after a window is reopened (`WorkspaceWindowChrome` re-hides the toggle on every window update); commit text edits on focus loss and popover close, not only on Return.
- A self-signed identity's designated requirement reads `certificate root = H"..."`, not `leaf` (one-certificate chain). The verifier accepts both.
- Mounted DMG apps carry Finder metadata that makes `codesign --verify --strict` fail; verify a copy made with `ditto --norsrc --noextattr --noqtn`.
- The app only enables Sparkle for HTTPS feeds, so an update test needs a local HTTPS server and a temporary trusted certificate. Sparkle's windows can be driven with System Events (Check for Updates is in Settings, General).
- Meeting and live transcripts saved without a recording have no media asset: show "No recording" (never Relink). Relink is only for an existing asset whose file is gone.
- Do not run `pkill swiftpm-testing-helper` while other agents test; it kills their runs.
- Agent worktrees can start from an old base: check that a task's prerequisites exist in the worktree and merge by cherry-pick, resolving conflicts deliberately.

- **Intelligence (1.2.0):** Apple Foundation Models have an 8192-token window (4096 on older 26.x) and no Sinhala. `Packages/Intelligence` summarises in stages, bounds every digest with `.maximumCount` (unbounded digests grew past the window), retrieves for chat, and computes chat sources itself (the model's own timestamps were wrong 3 times in 8). The real-model gate is `EARMARK_EVAL_INTELLIGENCE=1 swift test --no-parallel --filter AccuracyEval` in `Packages/Intelligence`; the lecture case takes a few minutes. Every FoundationModels symbol stays behind `#if canImport` and `#if compiler(>=6.4)` for `contextSize`. Hosted CI uses `ScriptedIntelligence`.
- UI tests can stop with "Timed out while enabling automation mode": macOS is showing "XCTest is trying to Enable UI Automation" and needs Touch ID or the password. Approve it and rerun.

## Where things are
`specs/` product, architecture, ADRs, change requests, design (`specs/design/m8-*`) and QA records (`specs/qa/README.md`). `scripts/` build, check and release tooling. `docs/` is the GitHub Pages site (deployed from `main`). `Brand/` app icon and brand assets.
