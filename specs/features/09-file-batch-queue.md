# 09 — File, Batch & Queue (FILE)
Status: Draft. Owners: UI engineers (views), Persistence/Transcription engineers (queue, pipeline).

## Scope
Inputs via drag & drop, picker, Finder "Open With", Services menu. Formats: anything AVFoundation decodes (mp3, m4a, wav, aiff, flac, caf, mp4, mov, m4v…), decoded to 16 kHz mono Float32 by `AudioFileDecoder`. Batch with per-batch settings and per-file overrides. Persistent queue with resume. Long-file chunking with VAD and checkpoints.

## AppCore protocols used
`JobQueue`, `JobRepository`, `AudioFileDecoder`, `VoiceActivityDetector`, `TranscriptionEngine`, `EngineRouter`, `Diarizer`, `TranslationRouter`, `TranscriptPostProcessor`, `Exporter`, `ModelManaging`, `HardwareTierProviding`, `TranscriptRepository`.

## Acceptance criteria (EARS)
- FILE-AC-01 (integration) WHEN the user adds files via drag/drop, picker, Open With or Services THE SYSTEM SHALL create one `Job` per decodable file with the batch `JobSettings`.
- FILE-AC-02 (unit) WHEN a folder is added THE SYSTEM SHALL recurse and enqueue only supported media types, honouring the type filter.
- FILE-AC-03 (UI) WHEN a file cannot be decoded THE SYSTEM SHALL mark only that job failed with a reason and a Retry action and SHALL continue the rest of the batch.
- FILE-AC-04 (UI) WHEN creating a batch THE SYSTEM SHALL allow engine/model ("Auto" default), language mode (default English), diarization, translation and auto-export settings with per-file overrides.
- FILE-AC-05 (integration) WHEN a job's model is not installed THE SYSTEM SHALL download it via `ensureAvailable` with visible progress and then run the job.
- FILE-AC-06 (unit) THE SYSTEM SHALL implement the queue state machine pending→running→(paused|failed|completed|cancelled) with pause/resume/cancel/retry transitions and reject illegal transitions.
- FILE-AC-07 (UI) WHEN the user reorders jobs THE SYSTEM SHALL honour the new order for scheduling; WHEN concurrency is changed THE SYSTEM SHALL apply it without restarting running jobs.
- FILE-AC-08 (integration) WHEN the app quits or crashes during a job THE SYSTEM SHALL resume from the last `JobCheckpoint` on next launch (PROD-AC-03) without duplicating committed segments.
- FILE-AC-09 (integration) WHEN a file exceeds the chunk size THE SYSTEM SHALL process VAD-bounded chunks with bounded memory and checkpoint after each chunk.
- FILE-AC-10 (unit) WHEN an engine throws THE SYSTEM SHALL convert it to a failed job (retryable) and SHALL NOT terminate the process (PROD-AC-02).
- FILE-AC-11 (integration) WHEN the job completes THE SYSTEM SHALL run post-processing (ignore filter → replacements), diarization and translation if enabled, save the transcript, and post a notification (batch-level notification for batches).
- FILE-AC-12 (integration) WHEN auto-export is configured THE SYSTEM SHALL write the export to the watch folder on completion.
- FILE-AC-13 (integration) WHILE on battery and "low priority on battery" is on THE SYSTEM SHALL lower QoS and reduce concurrency; WHILE thermal state is serious or critical THE SYSTEM SHALL throttle.
- FILE-AC-14 (UI) THE SYSTEM SHALL show per-job progress, ETA, engine and language, updating at ≥ 1 Hz.
- FILE-AC-15 (integration) WHEN memory pressure fires THE SYSTEM SHALL pause new job starts and allow `ModelManaging` to unload idle models.
- FILE-AC-16 (UI) WHEN the media is referenced (default) THE SYSTEM SHALL store a security-scoped bookmark; WHEN "copy into library" is chosen THE SYSTEM SHALL copy it and mark the asset library-owned.

## Edge cases
Empty queue state; duplicate file detection (offer skip/re-add); zero-length/silent audio produces an empty transcript with a notice; unreadable/DRM media fails with reason; disk full during copy.

## Non-functional
≥ 10× real-time with large-v3 turbo on M1 Pro-class (benchmarked 13–17× on M3 Pro); bounded memory independent of file length; queue operations < 50 ms.
