# SCR-009: Contract changes from the 2026-11-22 code review fixes

Status: Implemented with the review fixes (B5, B6, B10, B11, spec gaps 6 to 8). Source: `specs/qa/code-review-2026-11-22.md`.

Contract-visible changes (all additive or internal-protocol):

1. `LiveSessionEvent` (LiveCaptions) gains `case engineNotice(String)`. The orchestrator emits one per `LiveEngineSelection.warnings` entry once a session is running, so the Whisper fallback notice from `AppleAwareEngineRouter` reaches the user. The app maps it to an info `LiveNotice`. Exhaustive switches over `LiveSessionEvent` must handle the new case (only `App/LiveSupport.swift` does today).
2. `ResolvedDictationEngine` (Dictation) gains `warnings: [String]` (default empty), filled from `EnginePlan.warnings` by `RoutedEngineProvider`. `DictationController` posts each as an info `DictationNotice` through the existing `DictationNotifying` when a session starts.
3. `RemoteFile` (ModelStore) gains `hasSafeRelativePath` and `destination(in:)`. Model manifests with empty, absolute, `~`, backslash, `.` or `..` path components are rejected with `AppError.modelDownloadFailed` before any download starts (B10).
4. Internal `SinhalaRecognizing` (QwenASR, not public) changes from a token stream to `async throws -> String` that returns only when the model is idle. `MLXQwenRecognizer` is now an actor on a dedicated serial queue (no `@unchecked Sendable`). Trade-off: mlx-audio-swift's `generateStream` runs an unjoinable detached task, so the synchronous `generate` is used; a started utterance now runs to its token cap (`64 + 30 s` tokens) instead of stopping at the next token, and cancellation takes effect between utterances. The repetition guard is applied to the finished text.
5. Guard tests: the literal-colour rule now also scans LiveCaptions and Dictation; a new network guard fails when `URLSession`, `NWConnection`, `WKWebView`, Sparkle types and similar appear outside `Packages/ModelStore/Sources` and `App/AppUpdateController.swift`.

No behaviour of PROD-AC-01 or the privacy copy changes.
