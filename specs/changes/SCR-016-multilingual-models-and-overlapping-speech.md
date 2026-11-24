# SCR-016: Multilingual model support and overlapping speech

Status: owner approved the implementation plan. Foundation contract changes below are specified for implementation; remaining model and speaker contracts require their concrete designs here before implementation. This document does not certify runtime feasibility or model quality.

Plan: [Earmark 1.1.0 implementation and release](../releases/1.1.0-plan.md).

## Problems

- Model coverage, executable engine availability, task-specific language/direction coverage and system-asset readiness are not represented consistently across routing and UI.
- PartialSegment carries text/time/language but no speaker/stream identity. Concurrent target-speaker partials must not overwrite each other; finalized segments already have speakerID and time ranges, but overlap retention throughout Live/editor/jobs/exports is not proven.
- Live translation is activated through caption appearance flags and the target setting. Translation engine preference is stored but not passed into the composed runtime router.
- Existing model/preference/queue/transcript data must continue decoding and behaving correctly during the expansion.
- A larger catalog needs a compact Recommended/Installed page, a separate supported-model browser and validated imports; arbitrary Hugging Face weights cannot be treated as executable model support.

## Proposed contract work

1. Design additive model/task/language-direction/runtime-readiness metadata, including native vs buffered streaming, real speaker attribution and overlap recognition. Keep vendor frameworks outside AppCore.
2. Design stable per-stream/speaker partial identity and revision/finalization semantics; preserve compatibility with ordinary single-stream engines. Specify what happens during speaker reassignment, stop/flush, cancellation and resumption.
3. Define explicit live translation configuration independent of appearance, with engine selection, supported pair/readiness, status/failure behavior and migration from existing presets/settings. Keep original transcripts when translation fails.
4. Specify resource ownership and lifecycle coordination for simultaneous jobs/Live/translation. Avoid engine unload races and unsupported concurrent access.
5. Require backward-compatible Codable defaults and migration fixtures before changing persisted payloads. Add database migrations only if the proven representation requires them; preserve old jobs and user edits.
6. Define versioned import-profile compatibility/validation results and immutable source provenance separately from quality verification. Accept supported Hugging Face and local-folder sources through one staged, cancellable, atomic acquisition pipeline; preserve legacy WhisperKit imports and stable custom IDs.
7. Represent directional translation packs and shared dependency ownership explicitly. Use the same availability/selection/routing rules for curated and imported models; distinguish implemented curated-only families from families with an accepted import profile.

## Acceptance

- All existing engine adapters and persisted fixtures pass after contract updates.
- Tests prove two concurrent speaker partials/finals and translations retain identity without dropped text.
- Pickers, preflight, routing and actual engine execution agree on supported tasks/languages and explicit engine choice.
- New models require actual native-model acceptance reports; no descriptor-only support.
- Every model family in the release work register has a verified outcome or an explicit owner-approved scope change.
- Models UI remains compact with Recommended and Installed areas; broader families, variants and translation directions are discoverable through Add models/Browse all.
- Every advertised import profile has actual native inference acceptance, rejection fixtures, pinned provenance, correct capabilities and complete lifecycle integration. File-format recognition and a successful load do not establish full support or quality.
- User imports cannot execute remote repository code or silently alter language/direction/license capabilities; failed imports never replace existing working models.

## Foundation contract specification

- Add `EngineRouter.preparedPlan(for:) async throws` with a default implementation delegating to the existing synchronous `plan(for:)`. System-backed routers refresh readiness for the exact requested locale before planning. Existing conformers remain source compatible.
- Add the additive `LiveSessionEvent.translationFailed(reason:)` notification. Translation failure retains captions and emits a visible warning; cancellation is not reported as failure. This event is transient, not persisted.
- Persist Live translation enablement separately from caption appearance. Migrate the old preset translation flag once when no explicit enablement value exists. Target and engine reuse existing settings. Explicit engine selection cannot silently choose another engine, and licensing policy applies before cached results are served.
- No persisted transcript, job, partial-segment or database schema changes in this foundation step.

## Model metadata specification

- Add optional `ModelCapabilities.translationPairs` for explicit text-translation directions. `nil` preserves the legacy all-distinct-pairs behavior within a translation descriptor's language set; an empty set means no supported directions. Add `speechTranslationPairs`, defaulting to empty, for direct speech-to-text translation without implying TTS.
- Add optional `ModelCapabilities.streaming` (`buffered` or `native`) and `overlapRecognitionSpeakers`. Missing values make no implementation/overlap claim; ordinary speaker diarization remains distinct from recognition of simultaneously spoken text.
- Add optional `ModelDescriptor.provenance`, containing an immutable repository revision, relative artifact digests/sizes, import profile identity/version and format/native-inference validation level. Missing provenance preserves legacy decoding. This metadata does not execute code or grant a model capabilities; acquisition/validation still enforces accepted profiles and hashes.
- `ModelDescriptor.supportsTranslation` must enforce explicit direction sets before language-set fallback. Pair packs cannot advertise their reverse direction through a shared language set. Native acceptance and independent translation quality remain separate facts.

## Curated Qwen speech-detector acquisition

The broad Qwen profiles require the pinned Silero unified 256 ms v6.2.1 Core ML detector after real samples exposed false silence and poor cuts in the energy-only gate. Keep the existing Sinhala specialist's detector unchanged. A finite ModelStore recipe adds the detector's five SHA-256-pinned files to the general checkpoint's normal download manifest, under `EarmarkSupport/silero-vad-v6.2.1.mlmodelc`. The manifest is staged, verified, resumed and activated atomically with the recognizer. Its roughly 1 MB payload is owned by that model folder; deleting one checkpoint cannot remove another checkpoint's dependency. The descriptor's total size and combined Apache-2.0/MIT attribution include it. This does not establish a general shared-dependency or arbitrary-import mechanism.

General Qwen preparation validates and loads the local detector without network access. Incomplete installations fail with a reinstall explanation before loading MLX weights. Detector failures propagate rather than becoming silent audio. Recurrent state resets for each bounded analysis, preventing leakage across re-analysis or unrelated capture lanes. Native sample tests and old Sinhala regression remain separate acceptance gates.

## Translation language matching and native resource ownership

Add `ModelCapabilities.translationLanguageMatching` with `ModelTranslationLanguageMatching.primary` as the backward-compatible default and `.exact` for profiles accepting only explicitly mapped language identities. `ModelDescriptor.supportsTranslation` must require exact languages and exact directional pairs for `.exact`; it must not drop a requested script/region to manufacture support. The initial MADLAD native profile advertises 27 base codes with exact matching; unimplemented script/region variants fail visibly. Preserve the requested pair when consulting engines in the translation router; normalization belongs to each adapter. Existing metadata retains its prior primary-subtag behavior.

Use one native CTranslate2 worker pool for shipping NLLB, MADLAD and Marian handles. The pool serializes ownership changes and inference, evicts the previous family before loading another and reloads an evicted owner's retained checkpoint on demand. A stale release cannot unload another owner. Engines serialize load/inference/unload within their own handle as well. This pool addresses native text translation; global GPU/Core ML/MLX speech scheduling remains separate work.

## Native speech isolation and wire contract

Add a `SpeechNative` package with no AppCore/UI dependencies. Pin transcribe.cpp 0.4.2 at `cfa237c2551a4b2d3a56ff8fe5461e3c67c51772`, its reviewed Swift wrapper and matching public ABI hash. Build an arm64 macOS 26 dynamic framework with embedded Metal kernels and no runtime model downloads. Follow the upstream dynamic-framework link recipe: force-load each original static archive independently to retain same-basename objects and Objective-C metadata; merging archives with libtool is unsafe here. Preserve upstream licences and source/header/binary provenance. The package remains unregistered in the app until its adapter, packaging and actual-model acceptance pass.

Run native computation in `EarmarkSpeechWorker`, one model/session/active stream per process. The app transport owns admission, process cancellation/restart and bounded stdin/stdout, with a versioned, bounded JSON-lines protocol. PCM is finite mono float32 at 16 kHz; constrain frame size, run duration and output row counts before converting native counts/allocations. Every reply echoes request identity. Include actual model architecture/variant/backend/capabilities in readiness. Never infer streaming/translation/language support from a filename. Reject malformed command/state transitions, unsupported language/task requests and model truncation; do not publish a partial decode as a completed transcript.

Structured snapshots preserve original input-relative segment/word times, native one-based speaker IDs (zero absent), stream revision, received/committed/buffered milliseconds, and separate authoritative raw versus stable/volatile display text. No invented word timings or calibrated confidence. Snapshot extraction copies borrowed native pointers before the next mutation. Retain independent overlapping segment intervals rather than sorting/flattening away overlap. AppCore speaker events and persistence mappings still require their concrete follow-up design; native proof alone cannot enable overlap recognition in the app.

Worker profiles bind architecture, variant and the complete language inventory, independently of the model filename. Add the verified Nemotron 3.5 native profile with its 32 production locales; exclude the eight tokenizer-only adaptation locales. Base language codes map to documented profile defaults, while exact supported locales remain intact and unknown regions/scripts fail. This is worker support only, not app/catalog activation. The pinned backend leaves its detected-language accessor empty, so recover a language only from an unambiguous supported model-emitted locale tag in its unfiltered output. Do not guess from transcript text or treat a prompt-conditioned tag as regional accent detection. Clip genuine encoder-frame alignment to the actual supplied PCM duration; reject negative/reversed intervals and leave absent streaming word alignment absent.

Add separate diagnostic native profiles for Cohere March 2026 (`cohere_asr`, 14 languages, explicit source, file-only, no alignment) and Canary 1B v2 (`canary`, 25 recognition languages, explicit source, file-only). Bind the translation-target inventory and translation capability in both the worker and client handshake. Canary translation requests must match an explicit English-pivot direction, independently of recognition coverage; unsupported cross-language pairs, same-language translation and unimplemented locales fail before inference. The pinned Canary conversion excludes Latvian from AST, yielding 46 directions. NVIDIA's card claims English with 24 other languages, while its Latvian exclusion note concerns comparative evaluation. Investigate this conversion discrepancy rather than presenting it as an established limitation of the original model. These native profiles do not register app engines or substitute direct speech translation for text translation. App task/persistence contracts and broader quality acceptance remain required.

Sources for the Canary discrepancy: [NVIDIA model card, including Evaluation Notes](https://huggingface.co/nvidia/canary-1b-v2), [pinned conversion profile](https://github.com/handy-computer/transcribe.cpp/blob/cfa237c2551a4b2d3a56ff8fe5461e3c67c51772/scripts/convert-canary.py).

## Conservative recommendation fallback

Keep experimental ASR models selectable, but require an explicit `RecommendedUse` rule before automatic recommendations can choose one. The generic fallback must filter experimental entries rather than choose them merely because no stable model covers a language. Preserve the existing explicit Sinhala specialist rules and user selections. This aligns implementation with the recommender's existing documented contract; it does not certify new hardware/speed claims.

## Shared bounded native process transport

Add a vendor-free `NativeWorkerKit` package used by Translation, SpeechNative and native helper entry points. A cancellable FIFO owns each local process, a single outstanding request and bounded JSON-line framing. Use POSIX stdin reads in helpers, per-descriptor SIGPIPE suppression, background writes covered by the request deadline, and bounded reply buffering. Both cancellation and deadlines terminate the owned process with a hard-kill fallback. Wait for exit during cleanup before reusing a transport. Validate reply identity before accepting errors or output, and bind the full native profile handshake. Keep the existing explicit Debug Python reference path isolated; shipping helpers never load Python or download models. This fixes the older CTranslate2 transport's unbounded buffer, uncancellable waiters and write-before-timeout deadlock without changing persisted contracts.

## Native generative translation backend

Add a separate `TextGenerationNative` helper package, using llama.cpp at `9578bd3fe48b793cf193c2e4615ec2f24a2ea92a`, arm64/macOS 26, embedded Metal and no runtime network dependency. Native GGML libraries remain in separate helper processes from speech; do not link both native backends into the app. Bind binary/header/bridge/licence provenance. Support finite Hy-MT2 1.8B/7B and TranslateGemma 4B/12B profiles, their exact data-only language maps, architecture and checkpoint filenames. Use the upstream default translation instruction for Hy-MT2 and the exact text branch of the pinned TranslateGemma template. Verify prompts against Jinja references. Use deterministic greedy decoding for reproducible acceptance, a 4096-token context, at most 1024 generated tokens, fresh context per item, and explicit failure on context/output limits. Reject literal model control delimiters in transcript input instead of changing original text or letting it escape the prompt. Template compatibility and native smoke checks are not broad quality acceptance; keep entries unregistered until their native, quality, lifecycle, resource and packaging gates pass. No AppCore contract change in this backend step.

Custom `LicenseRef-...` model terms require acknowledgement before acquisition, except the existing Apple system-assets identity. This extends the existing computed `LicenseInfo.needsAcknowledgement` policy without changing its encoded shape. Existing non-commercial/share-alike checks remain in force; do not treat Gemma's custom terms as a plain permissive licence merely because `isNonCommercial` is false. Model downloads retain exact licence/notice material and attribution.

## Written-language identity and script-preserving translation

Add computed `LanguageCode.translationIdentity` and `LanguagePair.isSameWrittenLanguage`, with no encoded fields. Ordinary region-only tags retain the existing same-language skip (en-US/en-GB/en). Preserve explicit script subtags. For Chinese, default to Hans for the base tag and Hant for TW/HK/MO unless an explicit script overrides the region. Routing, Live, coordinator and readiness must not skip distinct scripts, and pivot planning must keep the original endpoint tags. Apple pair availability/inference receives script-preserving translation identities while retaining ordinary region normalization; its dynamic supported-language list retains minimal locale identifiers instead of stripping scripts. NLLB may normalize a region/default script only when it maps to the registered FLORES script; reject an unimplemented script rather than silently substituting one. Native NLLB language-set restrictions also apply to direct engine execution, not only router selection.

Saved translation tracks, editor rendering/search and exports must also match written-language identities; replacing one Chinese writing system must retain the other. Automatic translation routing prefers an installed eligible matching engine before a supported engine awaiting installation, retaining existing priority among equally ready candidates. Explicit engine choice remains binding. Readiness uses the same priority and installation policy. Apple responses require unique, complete, in-range item identities; every nonempty input needs a nonempty output before any row in that batch is attached.

Extend the existing serial translation worker pool to own both CTranslate2 and generative profiles. Share only the vendor-free `TextModelProfiles` product with Translation; the app must not link the llama framework. A lease spans checkpoint selection and inference, eviction awaits the previous worker's termination, and releasing a stale engine handle cannot unload the current owner's model. Generative adapters preserve segment identity and translate one input row per prompt. Each variant retains an independent model/engine identity. This enables backend acceptance without prematurely registering model choices in the shipping catalog.

Model residency eviction and memory-pressure cleanup must share the same admission gate as preparation and removal. Otherwise an eviction callback may still be releasing a heavy model while a new load starts. Expose NativeWorkerKit's vendor-free cancellable FIFO gate for ModelStore reuse; cleanup admission remains noncancellable and may return a Sendable result. ModelStore may depend on NativeWorkerKit for this synchronization only. Add an atomic prepare-and-begin-use operation for callers that need a model reservation across native load/inference; queued cancellation must not register a phantom resident model. This is a concrete resource-tracker API, not a new AppCore contract or a claim that all production engines already report leases.
