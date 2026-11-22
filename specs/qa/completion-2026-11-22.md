# Completion validation — 2026-11-22

This records implementation checks for the recovered M8 work, native Sinhala translation runtime and M7 release preparation. It does not close the manual acceptance or public distribution gates.

Host: Apple silicon, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2. The deployment target is macOS 26; an actual macOS 26 acceptance run remains required.

## Package and native checks

All 18 package suites passed in a serial run. DesignSystem and Features were rechecked after the final review fixes. Reported counts:

| Package | Tests |
|---|---:|
| AppCore | 9 |
| Persistence | 38 |
| DesignSystem | 72 |
| ModelStore | 30 |
| AudioCapture | 56 |
| Processing | 40 |
| Export | 22 |
| Permissions | 9 |
| Meetings | 86 |
| Translation | 47 |
| Transcription | 90 |
| Diarization | 51 |
| LiveCaptions | 75 |
| Dictation | 81 |
| Jobs | 39 |
| QwenASR | 21 |
| Features | 296 |
| NLLBNative | 2 |

Environment-dependent tests can be disabled in ordinary package runs. Native NLLB parity was additionally run with the real local model: both tests passed, including Unicode SentencePiece tokenization and beam-search translation against pinned Python reference outputs. The native-worker integration test separately passed translation, cancellation within one second and automatic restart, without Python in the app runtime.

The real Qwen suite ran the available local corpus: read speech CER 7.46% over 40 clips; conversational/code-mixed CER 21.47% over 60 clips (14.29% Sinhala-only, 27.97% code-mixed). RTF was 0.324 and 0.353 respectively on this development machine. These are corpus measurements, not a guarantee for other recordings or a minimum-hardware performance acceptance result.

DesignSystem checks include AA text tokens on supported surfaces, solid glass fallbacks, content-glass guards and raster visibility for all 25 custom symbols in both appearances. Features review fixes retain missing-media warnings/tags, video resizing, reactive Home model status, microphone error cleanup and reduced-motion scrolling. The final focused integration recheck passed all five tests. Screenshot review also bounded the missing-media panel, removed excess toolbar padding in Live and made the Meetings surface fill its pane.

`scripts/check-dependencies.py` passed for the 18-package graph. Changed Swift sources pass SwiftLint and swift-format checks; shell/Python tooling passes syntax checks. Xcode emits existing upstream MLX C++ warnings and an AppIntents metadata notice, so the entire dependency build is not claimed warning-free.

## UI and app checks

The final isolated XCUITest run passed all four tests with zero failures (132.3 seconds) against implementation commit `c2f0792`. It covers all six main routes in light/dark, Editor bookmarks/view options/Export/Quick Open, the narrow inspector and speaker transition, all five onboarding steps, and availability of all 15 Settings sections. There are 29 window screenshots under `specs/design/m8-shots/completion/`. The final result bundle is `/tmp/earmark-m8-ui-tests-final.xcresult`. The QA configuration uses in-memory services and a separate bundle identity; it does not download models, access the real library or prove TCC/capture behaviour. It explicitly opens the main scene for XCTest and places test windows on the primary monitor for window screenshots.

Package logs are under `~/Library/Caches/EarmarkBuild/reports`; final handover logs and `.xcresult` bundles are retained under `/tmp/earmark-*`. Screenshots committed under `specs/design/m8-shots/completion/` use mock content and are evidence for visual review, not automatic visual acceptance.

## Release boundary

Sparkle integration and local/distribution packaging scripts are implemented. The release-tooling subagent validated syntax, input rejection, signing order, archive/bridge provenance, payload exclusions and DMG-manifest fixtures. Native archive and bridge hashes match the checked-in provenance. Candidate-source review found no downloaded models, generated caches or detected private keys/tokens.

No Developer ID signing, notarization, Gatekeeper acceptance, published appcast or real update installation is established by these checks. The empty feed/key defaults keep the updater dormant. Follow [release.md](release.md) before distribution.

Open acceptance gates remain in [manual.md](manual.md): light/dark board comparison, VoiceOver and accessibility settings, large text/Sinhala shaping, target-hardware glass/memory profiling, real Zoom/Teams and two-track capture, TCC denial/retry, hot-plug, dictation insertion and crash recovery. The user will test the final real-services build from `main`.
