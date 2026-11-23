# SCR-015: Whole-row Queue activation and the editor's transcribing mode

Status: Additive. No schema, migration or persisted-data change; no AppCore type or protocol signature changes. Old jobs and
transcripts behave as before.

## Finding: progressive persistence already exists

The file pipeline (`PersistentJobQueue+Run`) already makes a transcript followable while its job runs, so no new storage was needed:

- The transcript header (`Transcript`) and its `MediaAsset` are created when the job starts (before model download and recognition),
  and `Job.transcriptID` is set at that moment. A job that is still `pending` and never started has no transcript yet.
- Each finalized chunk is written with `upsertSegments` (idempotent by segment id) and only then does the job's `checkpoint` advance;
  every checkpoint advance broadcasts `JobEvent.updated(job)`. A crash between the two is repaired on resume by `trimToCheckpoint`
  (segments at or after the checkpoint are dropped and transcribed again), so a resume never duplicates a segment.
- While running, the stored segments are the raw engine output. Speaker labels, ignore/replacement rules and the final header
  (languages, speakers, duration) are written once at the end by `replaceSegments` + `save`, exactly as before. The final result is
  therefore identical to previous behaviour; only the editor sees the intermediate raw state.
- A merge re-run (`JobSettings.rerun` without `replaceEverything`) still collects in memory and merges at the end (SCR-013); its
  transcript does not change until completion.

New Jobs tests pin this contract: segments and the header are readable while a job is running, a paused job keeps its partial
segments, and resuming keeps the already saved rows (same ids) without duplicates.

## Contract the editor relies on

- Segments of a transcript whose `transcribeFile` job is `pending`, `running` or `paused` are owned by the queue. Nothing else may
  write them. Observers learn about new chunks from `JobEvent.updated` (checkpoint change) and re-read `TranscriptRepository.segments`.
- `JobEvent.updated` with `state == .completed` means the final segments and header are stored; `.removed` means the queue entry is gone.
- A first-run job that is `failed` or `cancelled` leaves a partial transcript. A failed or cancelled merge re-run leaves a complete one.

## Features

### Queue (`FeatureQueue`)

- The "Open Transcript" button is gone. The whole row is a button (`DSHoverButtonStyle` highlight behind the content, pointer cursor,
  `.isButton` trait, "Open transcript" accessibility action, tooltip). Pause, Cancel, Resume, Retry and Remove keep working on top.
  Return opens the keyboard-selected row. A trailing chevron marks rows that open.
- Every job that has a `transcriptID` opens it: completed (editor), running/paused (live read-only mode), failed/cancelled (partial
  transcript). A `pending` job without a transcript is not activatable and says why.
- Remove is disabled while a job is running or pending (Cancel stops it first), with a tooltip. Retry exists only for failed and
  cancelled jobs.

### Editor (`FeatureEditor`)

- `TranscriptEditorModel` follows the job (`transcriptionJob`, from `JobQueue.jobs()` at load and `events()` afterwards). While the
  job is unfinished or stopped half-way, `isReadOnly` is true (`explicitReadOnly || transcriptionJob != nil`), so every edit,
  speaker, language, find-and-replace, ignore, translate, re-transcribe and relink path is refused at the model, and the matching
  toolbar, menu and context-menu items are disabled with "Available when transcription finishes".
- Segments appear as chunks complete; the list follows the newest segment until the user scrolls up, then offers "Follow latest".
  Playback, selection, copy, find (without replace), bookmarks and highlights stay available (they are stored separately from the
  queue's segment writes).
- A slim banner shows status, progress, ETA and Pause/Resume/Cancel. After a failure or cancellation it shows the reason with Retry
  and Remove; the saved segments stay visible read-only, or an empty state if none. Removing the job makes the partial transcript
  editable.
- On completion the final segments and header replace the live ones in place: no reload state, scroll position kept.

### Library

- Rows of transcripts whose job is in progress show a "Transcribing" pill, and the list refreshes when the row appears. Opening them
  uses the same editor and therefore the same read-only live mode.

## Not covered

- A job that has not started (no transcript yet) cannot be opened.
- During a merge re-run the transcript is read-only with the banner, but its segments do not change until the job completes.
- Renaming a transcript from the Library while its job runs is not blocked (the job's final header write wins, as before).
