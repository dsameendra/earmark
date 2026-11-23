# SCR-016: Multilingual model support and overlapping speech

Status: proposed contract design for the owner-requested 1.1.0 work; implementation pending. Exact API/schema changes must be reviewed before code changes. This document does not certify runtime feasibility or model quality.

Plan: [Earmark 1.1.0 implementation and release](../releases/1.1.0-plan.md).

## Problems

- Model coverage, executable engine availability, task-specific language/direction coverage and system-asset readiness are not represented consistently across routing and UI.
- PartialSegment carries text/time/language but no speaker/stream identity. Concurrent target-speaker partials must not overwrite each other; finalized segments already have speakerID and time ranges, but overlap retention throughout Live/editor/jobs/exports is not proven.
- Live translation is activated through caption appearance flags and the target setting. Translation engine preference is stored but not passed into the composed runtime router.
- Existing model/preference/queue/transcript data must continue decoding and behaving correctly during the expansion.

## Proposed contract work

1. Design additive model/task/language-direction/runtime-readiness metadata, including native vs buffered streaming, real speaker attribution and overlap recognition. Keep vendor frameworks outside AppCore.
2. Design stable per-stream/speaker partial identity and revision/finalization semantics; preserve compatibility with ordinary single-stream engines. Specify what happens during speaker reassignment, stop/flush, cancellation and resumption.
3. Define explicit live translation configuration independent of appearance, with engine selection, supported pair/readiness, status/failure behavior and migration from existing presets/settings. Keep original transcripts when translation fails.
4. Specify resource ownership and lifecycle coordination for simultaneous jobs/Live/translation. Avoid engine unload races and unsupported concurrent access.
5. Require backward-compatible Codable defaults and migration fixtures before changing persisted payloads. Add database migrations only if the proven representation requires them; preserve old jobs and user edits.

## Acceptance

- All existing engine adapters and persisted fixtures pass after contract updates.
- Tests prove two concurrent speaker partials/finals and translations retain identity without dropped text.
- Pickers, preflight, routing and actual engine execution agree on supported tasks/languages and explicit engine choice.
- New models require actual native-model acceptance reports; no descriptor-only support.
- Every model family in the release work register has a verified outcome or an explicit owner-approved scope change.
