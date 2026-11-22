# SCR-013: Unified add flow, speaker options, non-destructive re-transcribe, diarization failure tolerance

Status: Implements triage A item 4 and triage C sections 1, 2 and 6 (items 1, 6, 10 to 13, partly). Builds on SCR-011 (capabilities,
`ModelCompatibility`, `ModelRecommender`, preflight). Additive: no persisted data changes meaning.

## AppCore

- `Segment.isUserEdited: Bool` (default `false`, `decodeIfPresent`). Set by text edits, speaker assignment and language correction in the
  editor; propagated by split (both halves) and merge (either). Exported in JSON like `ignoreFlagIsManual` (goldens updated).
- `RerunOptions { ranges: [TimeRange]; replaceEverything: Bool; speakersOnly: Bool }` and `JobSettings.rerun: RerunOptions?`
  (`decodeIfPresent`). A `transcribeFile` job with a `transcriptID` and `rerun != nil` re-runs an existing transcript.
- `Job.warning: String?` (`decodeIfPresent`): a warning that survives completion. Job status notes are in memory only.

## Persistence

- Migration `v3-segment-user-edited` (append-only): `segment.isUserEdited INTEGER NOT NULL DEFAULT 0`; upsert and row decode updated.

## Jobs

- Merge re-run (default): the engine output is collected in memory (no checkpoint, an interrupt restarts the run), then merged by time
  range (`RerunMerge.merge`). A segment is locked when `isUserEdited || ignoreFlagIsManual`; locked segments and everything outside the
  ranges survive untouched. New segments inherit the speaker of the old segment they overlap most, and are dropped when they mostly cover
  a locked segment. Non-manual ignore flags follow the normal post-processing of the new text.
- `replaceEverything`: the previous behaviour (wipe and rebuild, speakers reset). The UI confirms first.
- `speakersOnly`: no recognition and no model/engine plan; only the speaker step runs on the existing segments.
- Identify speakers again on an existing transcript maps each new speaker to the existing speaker it overlaps most (each existing speaker
  once), so names and colours survive; unmatched speakers become "Speaker N" after the existing names; locked segments keep their speaker.
- DIA-AC-16: the speaker step (model download plus diarizer) never fails a file job. On error the job completes with no speakers and
  `Job.warning` ("Speakers could not be identified ..."). Pause and cancel still propagate.

## Features

- One add entry point: `QueueModel.requestAdd(_:)`, used by `ShellModel.requestAdd` for the window drop, importer, Home drop (via
  `HomeModel.requestAdd`), Queue add and folders. The Transcribe sheet (`BatchSettingsSheet`, now public) is hosted by the shell.
- Setting `files.askBeforeAdding` (absent means on). Settings > General has the toggle; the sheet has "Don't ask again, use these
  settings". When off, files are enqueued with the saved choices, which now include `files.diarize` and `files.speakerCount`.
- Remembered choices: `FileJobSettings.save` writes `defaults.languageMode`, `files.lastModel`, `files.diarize`, `files.speakerCount` and
  `files.recentLanguages` (max 5, most recent first). Language and model are written only when the user edited them. The model goes to a
  file-scoped key, not `defaults.preferredModel`, which live captions also read; `load` prefers `files.lastModel` ("" is an explicit
  Automatic) then falls back to `defaults.preferredModel`.
- Model rows come from `ModelChoices.rows` (`ModelCompatibility.evaluate` for `.file`, the chosen language(s), auto-detect and tier):
  unsupported rows are disabled and show their reasons; models this build cannot run are not listed. A model with an explicit
  `RecommendedUse` rule is preselected only when nothing is saved; otherwise the choice is Automatic, labelled with the recommendation.
- Speakers: "Identify speakers" plus expected count Automatic or 1 to 10 (`SpeakerCount`, maps to `JobSettings.diarization`
  `["exact": n]`). When the offline speaker model is missing the sheet shows its size, preflight notes and a Download button
  (`ensureAvailable`, which applies the preflight and consent hook).
- Editor: toolbar "Re-transcribe" popover (`RerunPanel`): scope (whole transcript or selected segments), language (one, several,
  automatic), model with greyed-out unsupported options, "Re-transcribe the speech" toggle, "Identify speakers again" with expected
  count, "Replace everything" (confirmation). It enqueues a job with `RerunOptions`; the editor saves first, is read-only while the job
  runs and reloads segments and header when it ends. Also "Set Transcript Language" (relabels segments for one language, no
  recognition; the header language set is no longer re-widened by segment languages afterwards).
- Library "Re-transcribe" now enqueues a merge re-run (`RerunOptions()`), no speaker work: edits, manual ignore flags, speaker names
  and segment ids are kept (fixes the data-loss defect).

## Not in this change (deferred)

- Single-step undo for a job-based re-run (undo history is cleared when the job finishes).
- A partial-range run still transcribes the whole file and merges only the ranges (no audio clipping yet).
- Editor popover model download button (the job downloads a missing model itself; the add sheet shows size and download for the
  speaker model only).
- Multi-language per-file overrides; live speaker-model download; remembering translation and auto-export between sheets.
- Speaker-name entry in the Re-transcribe popover; voice-profile based speaker matching.
