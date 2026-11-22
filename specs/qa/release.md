# Release preparation and verification

The scripts prepare a macOS 26+ Apple-silicon app. A **local** package is ad-hoc signed for testing. A **distribution** package requires Developer ID signing and successful Apple notarization. Neither command publishes a release, pushes an appcast, or uploads an artifact to an update host.

## Before packaging

1. Commit the intended source and review the task/QA status. Run the unit, build and UI checks in `scripts/check.sh`; review the saved light/dark screenshots against the M8 boards. Real microphone, app-audio, dictation-insertion, recording-recovery and hardware checks remain separate manual gates.
2. Keep `Config/Package.resolved` current with the reviewed dependency graph. `scripts/project.sh` generates the Xcode project outside cloud-synced Documents and installs that lock.
3. Ensure `App/Resources/ThirdPartyNotices.txt` and `NativeRuntimeLicences.txt` accompany the app. The native runtime is checked against `Packages/NLLBNative/Vendor/provenance.json`; rebuilding its C bridge or archive requires reviewing and updating those hashes.
4. Check the marketing version and monotonically increasing build number in `project.yml`. The completed build's `Info.plist`, rather than a filename, supplies artifact versions.

## Local review package

```sh
scripts/release.sh local
```

This creates a new directory under `dist/`, builds Release in the local build cache, copies only `Earmark.app` into staging, signs nested code inside out with an ad-hoc identity, validates the bundle, and creates a compressed DMG with an `/Applications` link. Local packages have no configured update feed or public update key, even if those variables exist in the invoking shell.

The verifier checks:

- Bundle identity, version, minimum OS, app/helper arm64 architecture and executable modes.
- Embedded Sparkle, the native translation helper, and third-party notices.
- Absence of model weights, Python files/frameworks, databases, credentials and development caches.
- App-contained symlinks, system/bundle-relative dynamic dependencies and runtime search paths.
- Deep, strict code-signature validation.
- DMG integrity and a read-only mounted root allowlist; file bytes, permission modes and symlink targets must match the staged app exactly.

The output directory contains `app-manifest.json`, `dmg-verification.json`, `build-provenance.json`, the DMG, its portable `.sha256` sidecar and the build log. `EARMARK_RELEASE_ROOT` can select a **new, unused** output directory. `EARMARK_RELEASE_DERIVED_DATA` can select a reusable build cache. The scripts refuse to reuse an output directory.

A local package is not notarized or approved for public distribution. Successful packaging also does not establish transcription quality, permission behaviour, visual acceptance or M1/8 GB performance.

## Developer ID distribution

Required inputs are a valid **Developer ID Application** identity in Keychain, the actual HTTPS appcast URL, the corresponding 32-byte Ed25519 public key, and a working `notarytool` Keychain profile. Apple Development identities do not satisfy this gate.

```sh
export EARMARK_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export EARMARK_UPDATE_FEED_URL='https://YOUR-HOST.example/earmark/appcast.xml'
export EARMARK_SPARKLE_PUBLIC_KEY='YOUR_BASE64_PUBLIC_KEY'
export EARMARK_NOTARY_PROFILE='earmark-notary'
scripts/release.sh distribution
```

Replace every example value. This command **submits the signed app and DMG to Apple** for notarization using the named profile. It validates configuration and native provenance before building and requires committed release source/tooling. Private keys and account credentials stay outside the repository; the Sparkle public key is deliberately embedded in `Info.plist`.

Signing preserves existing nested-helper entitlements, applies Earmark's microphone entitlement to the outer app, and adds secure timestamps and hardened runtime for Developer ID code. The script requires an `Accepted` notarization result, staples and validates the app ticket, performs a Gatekeeper assessment, then packages, signs, notarizes and staples the DMG. Final verification compares the mounted image with the already-stapled staged app and checks the DMG signature/ticket.

Archive the JSON notarization responses and validation manifests with the released artifact. Do not present a partially successful build, an unaccepted notarization submission or an ad-hoc DMG as a finished public release.

## Sparkle publishing gate

The client stays dormant when its feed/key configuration is absent or invalid; automatic checks default off and require user opt-in. Configure the real feed and public key together. Create/sign the appcast with the tools from the **pinned Sparkle release** and its matching private key, validate its enclosure URL and version/build, then publish only after release approval. The scripts intentionally do not invent a hosting destination, generate a private key, or upload an appcast.

Implementation references: [Sparkle setup and signing requirements](https://sparkle-project.org/documentation/), [Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), and [Apple's nested-code signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

## Validation status of this tooling

During implementation, shell/Python syntax and lightweight temporary-fixture checks covered URL/key rejection, nested signing order, byte/mode changes, model-weight rejection, escaping links and unexpected DMG payload. A signing dry-run can inspect the real bundle without changing it:

```sh
python3 scripts/sign-bundle.py /path/to/Earmark.app --identity - --entitlements App/Earmark.entitlements --dry-run
```

Actual Release packaging, image mounting, Developer ID signing/notarization and update installation must be reported from executed runs. Script inspection and fixture tests do not count as those results.
