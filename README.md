# Earmark

A local macOS transcription app for files, meetings, live captions and dictation, with transcript editing and translation. Requires **macOS 26 or later on Apple silicon** and an Xcode toolchain supporting Swift 6.2.

The implementation includes the M8 Ember/paper/ink design, native Sinhala translation and release preparation tooling. Visual acceptance, real permission-gated capture, accessibility and hardware performance checks remain open; this is not a completed public release. See the [execution record](specs/tasks.md#execution-record-codex-handover-2026-11-22), [manual QA](specs/qa/manual.md) and [release gates](specs/qa/release.md).

## Build and run

Install Xcode command-line tools and XcodeGen. Generate the project outside cloud-synced Documents so Xcode file coordination does not stall:

```sh
scripts/project.sh
```

The script prints the generated project path, normally `~/Library/Caches/EarmarkBuild/Earmark.xcodeproj`. It links the repository sources and copies the reviewed `Config/Package.resolved`. Open that project, select the **Earmark** scheme and **Debug**, then Run. A normal Debug launch uses real local services; microphone, system-audio and Accessibility permissions are requested by the relevant features. Use a signing identity when testing TCC persistence across rebuilds.

For a command-line build with an explicit output location:

```sh
project="$(scripts/project.sh)"
xcodebuild -project "$project" -scheme Earmark -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Caches/EarmarkBuild/Development" \
  -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
open "$HOME/Library/Caches/EarmarkBuild/Development/Build/Products/Debug/Earmark.app"
```

This unsigned development build establishes compilation; it does not validate distribution signatures or stable permission identity. Use Xcode signing or the local packaging flow when those matter.

## Checks

```sh
scripts/check.sh unit   # dependency direction and 18 serial package suites
scripts/check.sh build  # dependency direction and Debug app build
scripts/check.sh ui     # deterministic mock-service XCUITests, DebugUI configuration
```

Reports go to `~/Library/Caches/EarmarkBuild/reports` unless `EARMARK_REPORT_ROOT` is set. UI tests use mock services and a separate QA bundle identity; they do not prove real recording, transcription quality or permission behaviour. Light/dark screenshots are attached to the Xcode test results for review against [the final local design boards](specs/design/m8-mockups/index.html). All 18 package suites passed during completion validation; real-model parity and native cancellation/restart were also run explicitly. All four final mock UI tests passed. See [completion validation](specs/qa/completion-2026-11-22.md), [window screenshots](specs/design/m8-shots/completion/README.md) and the manual gates.

## Models and translation

Download models explicitly in Settings → Models; model weights are not bundled. Sinhala ASR uses Qwen3-ASR. Sinhala translation uses the bundled native **CTranslate2 4.6.0 / SentencePiece 0.2.1** worker and separately downloaded NLLB weights. No user-installed Python is required. NLLB weights retain their **CC-BY-NC-4.0** restriction; the native runtime does not change their licence.

See [ADR-009](specs/decisions/ADR-009-nllb-runtime.md) for runtime selection and [NativeRuntime](NativeRuntime/README.md) for rebuild and real-model parity checks. Python is only an explicit Debug development/reference override; Release always uses the bundled native helper.

## Release preparation

```sh
scripts/release.sh local
```

This prepares an ad-hoc local review DMG and validation manifests. It does not publish a release or establish Developer ID/notarization acceptance. Public distribution additionally requires the real signing identity, notarization profile, HTTPS update feed and Sparkle public key, plus completed QA. Follow [the release procedure](specs/qa/release.md).

The update client is dormant without valid feed/key configuration. Automatic update checks default off and require user opt-in. Local audio stays on the Mac; explicitly chosen model/language-pack downloads and configured update checks use the network.

Project specifications, acceptance criteria and the preserved milestone plan live in [specs](specs/00-product.md).
