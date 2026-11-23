# Earmark 1.0.1 release verification

Version 1.0.1, build 2. The release DMG was built from clean commit `d3cdf6b935adaa3826ebec2ee28998dbf785f5be`; the release tag must identify that commit. Subsequent tooling/documentation commits do not change the shipped app.

## Automated evidence

- CI run 45212643483: static, hosted macOS Debug build and all 18 package unit suites passed for the artifact source commit. CodeQL run 45212643339 passed.
- Local full UI suite: 13 tests, zero failures, completed 2026-11-23 21:41:35 +0530. Evidence: EarmarkBuild/reports/xcode-test.log and Test-Earmark-QA-2026.11.23_21-36-08-+0530.xcresult.
- Release packaging: self-signed app, 159 payload entries, 7 Mach-O binaries; DMG payload, installer artwork/layout and checksum verified. Reports remain in dist/release-1.0.1.
- Resumed release-tool checks: 27 fixture tests passed, dependency boundaries passed, website validation passed, no tracked key material, shell syntax and diff whitespace checks passed. Backup-file signing was exercised using the pinned Sparkle tools in an isolated temporary output directory.
- CryptoKit verified the DMG Ed25519 signature against the identical public keys embedded in the old and new apps. Both apps pin the same self-signed certificate in their designated requirements.

## Signed app smoke checks

Executed against the staged signed Release app, not the mock UI build:

- Main window has no sidebar toggle or empty glass-circle remnant.
- Zoom and Teams policy changes update their toolbar labels. Original policies restored: Zoom Auto-transcribe; Teams Auto-transcribe + record.
- Existing transcript-only meeting opens with No recording, an explanation and no Relink control.
- Re-transcribe explains that no recording exists and disables Start.
- Settings opens and reopens without the sidebar toggle.

## Real Sparkle update

A signed copy of 1.0.0 with its feed redirected to local HTTPS found 1.0.1, downloaded the actual release DMG, extracted it, installed it through Install and Relaunch, and relaunched successfully. About displayed Version 1.0.1; installed Info.plist reports build 2 and restores the production HTTPS feed URL.

A clean ditto copy of the installed app passed deep strict self-signed verification. All 159 installed payload entries match the staged release's bytes, permissions and symlinks. The original installed copy acquired Finder metadata during extraction, so strict verification used the documented metadata-free copy procedure.

The test HTTPS server was stopped after installation. Temporary certificate trust was removed, verification returned CSSMERR_TP_NOT_TRUSTED again, and the temporary certificate was deleted from the login Keychain. A fresh read-only DMG verification also passed after the update test.

## Scope limits

This pass verifies the release regressions and actual update installation. It does not repeat real microphone/system-audio recording, dictation insertion, model-quality evaluation, or physical macOS 26 hardware testing. Hosted macOS unit checks and the earlier UI result remain separate evidence. Distribution is self-signed and not notarized.

## Published release

Published as the normal latest release: https://github.com/dsameendra/earmark/releases/tag/v1.0.1. Remote tag v1.0.1 points exactly to the build-provenance commit d3cdf6b935adaa3826ebec2ee28998dbf785f5be. Assets are Earmark-1.0.1.dmg, Earmark-1.0.1.dmg.sha256 and appcast.xml. The live latest/download/appcast.xml is byte-identical to the verified local feed and includes both 1.0.1 and 1.0.0. GitHub Verify release run 45223750018 passed.

DMG SHA-256: 5b375282278fcf69e847d9a3ec7318aba1338e7ab8ff2b884000362a4161e13d.
