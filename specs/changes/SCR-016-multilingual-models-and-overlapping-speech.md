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
