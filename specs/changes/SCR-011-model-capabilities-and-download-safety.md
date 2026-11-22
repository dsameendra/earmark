# SCR-011: Model capabilities, one recommender, and download safety

Status: Implements wave 1 of `specs/qa/triage-C-2026-11-22.md` (sections 3, 5 and 6 items 2 and 3). Additive: no existing
persisted data or public call changes meaning.

## AppCore additions

- `ModelCapabilities` on `ModelDescriptor.capabilities` (`live`, `file`, `wordTimestamps`, `autoDetectLanguage`, `speakerLabels:
  SpeakerSupport`, `translation`, `speed: SpeedTier?`, `memory: MemoryTier?`, `recommendedUse: [RecommendedUse]`). Languages stay on
  `ModelDescriptor.languages`. Unmeasured speed and memory are `nil`; nothing is invented. Decoding uses `decodeIfPresent` with the
  conservative `.standard` value (file transcription only) so `state.json` written before this change still loads.
- `ModelDescriptor.downloadInclude: [String]` (repo-relative path prefixes; empty means everything under `sourceURL`).
- `ModelDescriptor.isRunnable` (`live || file`) and `covers(_:)`. A listed model that is not runnable (Parakeet: no registered engine)
  is excluded from `LanguageCapabilityTable`, never recommended, and reported as `.notRunnableInThisBuild`.
- `ModelRecommender.recommendedModel(for:useCase:language:in:availableEngines:allowFallback:)`: the single tier-to-default rule, data
  driven by `RecommendedUse` rules. It replaces `DefaultEngineRouter.fileWhisper`, `PreferredModel.fileModels` defaults and
  `OnboardingLanguageModel.fallbackModel`. The router passes `allowFallback: false` so it stays table driven.
- `ModelCompatibility.evaluate(_:for:tier:availableEngines:) -> ModelAvailability` returning `.ok` or `.disabled([ModelIncompatibility])`;
  each reason has a stable `message`.
- `ModelManaging.preflight(_:) -> ModelPreflightResult` and `retryDownload(_:)` (both with default implementations),
  `ModelPreflightIssue`, `ModelDownloadConsenting`.

## ModelStore changes

- Catalog: LS-EEND, Sortformer, Community-1 and Parakeet download only their needed files (`downloadInclude`); every Hugging Face source
  is pinned to a commit; catalog sizes are the real manifest totals (21.6 MB, 44.6 MB, 486.8 MB, 483 MB); MADLAD gets its exact size and
  SHA-256; Whisper tokenizers are fetched from pinned revisions. A named include missing from the listing is an error.
- Downloads: non-2xx responses surface as `DownloadHTTPError`; real failures as `DownloadFailedError` (only a user cancel is
  `DownloadInterruptedError`). Stale resume data (expired signed CDN URL, 403) is deleted and the file restarts cleanly. Transient
  failures (429, 5xx, dropped connection) retry with exponential backoff (`RetryPolicy`); offline fails at once with
  `DownloadMessage.offline`. Manifest requests follow `Link: rel=next` pages and are retried the same way.
- Failed rows: `cancelDownload` on a failed model discards the failure and partial data; `retryDownload` restarts cleanly.
- Preflight and consent: `ModelManager.ensureAvailable` runs `preflight` first. Insufficient disk (real size plus 20%) refuses the
  download. When the preflight `requiresConsent` (non-commercial or share-alike licence, hardware below `minTier`) and a
  `ModelDownloadConsenting` hook is installed, the hook is asked once per model and the answer is persisted. No hook means no gate.

## Not in this change

UI (wave 2), the per-use-case preferred-model keys, the unified add flow, and a `fluidaudio` ASR engine for Parakeet.
