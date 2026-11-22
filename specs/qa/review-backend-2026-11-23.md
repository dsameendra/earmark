# Backend/data review, 2026-11-23 (changes since 84365c5)

Scope: Jobs, ModelStore, Persistence, AppCore (RerunOptions, capabilities, recommender), Transcription router, App/ callers.

## Confirmed bugs fixed (tests added)

1. **Medium, data loss: re-run merge deleted long segments that only grazed the range.** `RerunMerge.inScope` used any-overlap
   for old segments but midpoint for new ones, so an old segment overlapping a scoped range by a fraction of a second was removed
   while its replacement (midpoint outside) was dropped, leaving a hole. Both sides now use the midpoint rule.
   Test: `grazingSegmentKept`.
2. **Low, data loss: translations were dropped on re-done segments** even when the new text was identical. Identical-text
   replacements now inherit the old translations. Test: `translationsSurvive`.
3. **Medium, silent failure: declining the licence/hardware confirmation for the diarization model finished the job with no
   speakers and no warning.** The model manager reports a declined confirmation as `AppError.cancelled`, which `diarizeSafely`
   treats as a pause/cancel. `ensureModel` now converts a `.cancelled` that nobody requested (no pause/cancel intent, task not
   cancelled) into `modelDownloadFailed("... was not confirmed ...")`, so diarization yields the DIA-AC-16 warning.
   Test: `declinedDiarizationModelWarns`.
4. **Low, UX: declining the ASR model confirmation failed the job with the reason "Cancelled."** Now "X was not confirmed for
   download. Retry and confirm to continue." Test: `declinedAsrModelFails`.
5. **Medium, resume blocked: preflight required full-size free disk even when most of the payload was already on disk**, so
   resuming/retrying a large download on a nearly full volume was refused. Needed space now counts only the missing bytes.
   Test: `resumeCountsPartialBytes`.
6. **Low, UX: the copy-into-library failure note was erased immediately** (the next step clears the status note). It is now also
   stored as the job `warning` (cleared at the start of each run, merged with a diarization warning at completion).

## Found, not fixed

- A re-run range that cuts a long old segment in the middle (midpoint inside the range) replaces it with fresh segments whose
  midpoints are inside; fresh text for the part outside the range is dropped. Inherent to segment-level merging.
- An empty fresh result (engine produced nothing) wipes all unlocked in-scope segments. Could be genuine silence, so left.
- Re-diarizing with `ranges` set relabels unlocked segments outside the ranges too (diarization is whole-file). Locked segments
  keep their speakers. Restricting needs a signature change to `remapSpeakers`; left for a design decision.
- New speakers get colour by slot number and can duplicate an existing speaker's colour.
- `URLError.cancelled` not caused by the user is still treated as a pause in `Transfer`.
- Sinhala is recommended on 8 GB Macs although Qwen has `minTier: .tier16` (by design; the preflight asks for confirmation).
- `diarizeSafely` warnings embed `String(describing: error)`; wording is technical.

## Verified OK

Migrations v2/v3 (additive ALTER with default, premigration backup, existing tests); `isUserEdited` is written/read in the only
segment INSERT; replaceEverything wipes via `trimToCheckpoint(nil)`; consent dedupe and re-check after the gate; 403 resume
recovery terminates (resume data dropped once); offline keeps resume data; preferred-model legacy migration is idempotent and
never overwrites a newer file key; recommender gives the intended pick for file/live/dictation, auto-detect and Sinhala, and
never recommends the non-runnable Parakeet or non-commercial NLLB.

## Tests

`swift test`: Packages/Jobs 58 tests pass; Packages/ModelStore 68 tests pass.
