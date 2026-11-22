# Release preparation and verification

The scripts prepare a macOS 26+ Apple-silicon app in three modes. A **local** package is ad-hoc signed for testing. A **selfsigned** package (the planned public channel, no paid Apple account) is signed with a stable self-signed certificate and updated through a Sparkle EdDSA key; it is **not notarized**. A **distribution** package (optional, only if a Developer ID account is ever obtained) requires Developer ID signing and successful Apple notarization. No command publishes a release, pushes an appcast, or uploads an artifact to an update host.

## Before packaging

1. Commit the intended source and review the task/QA status. Run the unit, build and UI checks in `scripts/check.sh`; review the saved light/dark screenshots against the M8 boards. Real microphone, app-audio, dictation-insertion, recording-recovery and hardware checks remain separate manual gates.
2. Keep `Config/Package.resolved` current with the reviewed dependency graph. `scripts/project.sh` generates the Xcode project outside cloud-synced Documents and installs that lock.
3. Ensure `App/Resources/ThirdPartyNotices.txt` and `NativeRuntimeLicences.txt` accompany the app. The native runtime is checked against `Packages/NLLBNative/Vendor/provenance.json`; rebuilding its C bridge or archive requires reviewing and updating those hashes.
4. Check the marketing version and monotonically increasing build number in `project.yml`. The completed build's `Info.plist`, rather than a filename, supplies artifact versions.

## Local review package

```sh
scripts/release.sh local
```

This creates a new directory under `dist/`, builds Release in the local build cache, copies only `Earmark.app` into staging, signs nested code inside out with an ad-hoc identity, validates the bundle, and creates a compressed DMG with an `/Applications` link. The installer uses Earmark's paper/ink/Ember artwork, Retina background, native volume icon and a 660 × 420 Finder window with two 128 pt icons and a clear drag direction. Local artwork is labelled as a preview. Local packages have no configured update feed or public update key, even if those variables exist in the invoking shell.

Like Downer's installer workflow, layout is authored through `dmgbuild`, without scripting Finder. Signing stages are created outside cloud-synced Documents in the build cache, using a copy without resource-fork/extended-attribute detritus. `build-provenance.json` records that staged app's location. `scripts/make-dmg.sh` installs the pinned packaging-only tools from `scripts/dmg/requirements.txt` into the external build cache on first use. These Python tools are never bundled in the app or image. The artwork source is `scripts/dmg/make-background.swift`; Finder settings are in `scripts/dmg/settings.py`. See the [dmgbuild settings reference](https://dmgbuild.readthedocs.io/en/stable/settings.html).

The verifier checks:

- Bundle identity, version, minimum OS, app/helper arm64 architecture and executable modes.
- Embedded Sparkle, the native translation helper, and third-party notices.
- Absence of model weights, Python files/frameworks, databases, credentials and development caches.
- App-contained symlinks, system/bundle-relative dynamic dependencies and runtime search paths.
- Deep, strict code-signature validation.
- DMG integrity and a read-only mounted root allowlist; file bytes, permission modes and symlink targets must match the staged app exactly.
- Branded metadata is limited to `.DS_Store`, `.background.tiff` and `.VolumeIcon.icns`. Background/icon hashes must match the authored assets, and parsed Finder metadata must match the reviewed window size, icon positions, label sizes, hidden chrome and confined background alias.

The output directory contains `app-manifest.json`, `dmg-verification.json`, `build-provenance.json`, `installer-artwork/`, the DMG, its portable `.sha256` sidecar and the build log. `EARMARK_RELEASE_ROOT` can select a **new, unused** output directory. `EARMARK_RELEASE_DERIVED_DATA` can select a reusable build cache; `EARMARK_SOURCE_PACKAGES_DIR` can reuse an existing Xcode package checkout cache. The scripts refuse to reuse an output directory. `EARMARK_DMG_PYTHON` optionally selects a Python environment already containing the exact pinned packaging versions.

A local or self-signed package is not notarized; only a local package is unapproved for public distribution. A self-signed package is the intended public channel once the manual gates pass. Successful packaging also does not establish transcription quality, permission behaviour, visual acceptance or M1/8 GB performance.

## Self-signed release (no Apple account, no notarization)

This is the plan of record. Gatekeeper will not recognise the publisher, so users approve the app once (see the README): **System Settings → Privacy & Security → Open Anyway**, or `xattr -dr com.apple.quarantine /Applications/Earmark.app`. Do not describe the app as notarized or Apple-verified. Sparkle updates download through Sparkle itself, are authenticated by the EdDSA signature and are not quarantined, so users see the Gatekeeper prompt only for the first install.

One-time setup (all keys stay in the login Keychain; nothing is written to the repository):

```sh
scripts/make-signing-identity.sh        # creates 'Earmark Release Signing' (10-year, Code Signing EKU); idempotent
scripts/make-appcast.sh keys            # creates the Sparkle EdDSA key if absent and prints the PUBLIC key
```

Back up **both** secrets immediately and store them outside the repo: the certificate identity as a `.p12` (Keychain Access → Export, or the command the script prints) and the Sparkle private key (`generate_keys -x FILE`). Sparkle accepts an update when at least one of the EdDSA key or the code-signing identity is unchanged, so losing either is survivable only if the other is kept; losing both strands every installed copy.

**Why the identity must never change.** For a self-signed identity codesign's designated requirement is `identifier "lk.dumindu.earmark.Earmark" and certificate leaf = H"<SHA-1 of the certificate>"`. The pinned certificate hash, not the build or the version, is what macOS privacy (TCC) grants (microphone, system audio, Accessibility) and the user's approvals are matched against, so permissions survive across versions only while every release is signed by the same certificate. A regenerated certificate has a different hash and users would have to re-grant everything. `scripts/verify-release.py --require-self-signed` fails any build whose requirement is not this identifier-plus-leaf form (for example a bare `cdhash`, which changes every build) or whose app, helper and Sparkle are signed by different identities.

```sh
export EARMARK_SIGN_IDENTITY='Earmark Release Signing'
export EARMARK_UPDATE_FEED_URL='https://github.com/dsameendra/earmark/releases/latest/download/appcast.xml'
export EARMARK_SPARKLE_PUBLIC_KEY='PUBLIC_KEY_PRINTED_BY_make-appcast.sh_keys'
EARMARK_RELEASE_DRY_RUN=1 scripts/release.sh selfsigned   # validates inputs only, builds nothing
scripts/release.sh selfsigned
scripts/make-appcast.sh appcast dist/Earmark-selfsigned-…
```

`selfsigned` mode requires all three variables, an HTTPS feed, a 32-byte public key, a valid Keychain identity whose certificate is self-signed (subject equals issuer; Developer ID, Apple-issued and ad-hoc identities are refused) and committed release source. It performs the same bundle, payload, dependency and DMG verification as the other modes plus: update configuration embedded in `Info.plist`; app, native helper and Sparkle signed by one non-ad-hoc, non-Developer-ID identity; and a certificate-anchored designated requirement shared by app and helper. It has **no** notarization, stapling, Gatekeeper-acceptance or secure-timestamp assertions. It deliberately omits the hardened runtime: a self-signed certificate has no Team ID, so library validation would refuse to load the embedded Sparkle framework, and without notarization the runtime flag buys nothing. The DMG background carries an "Open Anyway" first-launch hint. The DMG itself is not signed.

`scripts/make-appcast.sh appcast RELEASE_DIR` uses the pinned Sparkle release's tools (`EARMARK_SPARKLE_BIN`, or the package artifacts in the build cache) to sign the DMG with the Keychain EdDSA key and writes `appcast.xml`, then `scripts/verify-appcast.py` checks the HTTPS enclosure, length, EdDSA signature shape and version/build against `app-manifest.json`. Set `EARMARK_PREVIOUS_APPCAST` so earlier versions stay in the feed, and `EARMARK_DOWNLOAD_URL_PREFIX` to override the default `https://github.com/dsameendra/earmark/releases/download/v<version>/`.

Hosting (manual, after release approval; the scripts upload nothing): create the GitHub release `v<version>` for `github.com/dsameendra/earmark`, attach the DMG, its `.sha256` and `appcast.xml`. The feed URL above then always resolves to the newest release's appcast. GitHub Pages is an alternative home for `appcast.xml` if a stable non-release URL is preferred; the feed URL baked into the app cannot be changed without shipping a new build, so choose it once.

Fixture tests: `python3 -m unittest discover -s scripts/tests`.

## Developer ID distribution (optional, requires a paid account)

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
