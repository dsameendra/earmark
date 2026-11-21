# 10 — Library & Data Management (LIB)
Status: Draft. Owners: UI engineers, Persistence engineer (GRDB + FTS5, ADR-001).

## Scope
All transcripts with full-text search, filters, sort, folders, tags, grid/list; soft delete with Recently Deleted (retention default 30 d, configurable), revisions, media handling and relink, storage management.

## AppCore protocols used
`TranscriptRepository`, `MediaRepository`, `MeetingRepository`, `SettingsStore`, `JobQueue` (re-transcribe), `ModelManaging` (disk usage).

## Acceptance criteria (EARS)
- LIB-AC-01 (unit) WHEN `list(LibraryQuery)` runs THE SYSTEM SHALL apply text, source, language, date, duration, speaker, tag and folder filters and the chosen sort, excluding soft-deleted rows unless `deletedOnly`.
- LIB-AC-02 (integration) WHEN the user types a search THE SYSTEM SHALL return full-text hits (FTS5) including Sinhala text with snippet and time, within 200 ms for 5,000 transcripts.
- LIB-AC-03 (integration) WHEN the Library opens with 5,000 transcripts THE SYSTEM SHALL load the list in < 500 ms (list queries SHALL NOT read word data).
- LIB-AC-04 (UI) THE SYSTEM SHALL offer grid and list layouts and persist the choice.
- LIB-AC-05 (UI) THE SYSTEM SHALL support rename, duplicate, move to folder, tag/untag, delete, and re-transcribe with different settings.
- LIB-AC-06 (integration) WHEN a transcript is re-transcribed THE SYSTEM SHALL create a new revision linked by `revisionOf` and keep the old version accessible.
- LIB-AC-07 (unit) WHEN an item is deleted THE SYSTEM SHALL set `deletedAt` (PROD-AC-08) and show it only in Recently Deleted; WHEN restored THE SYSTEM SHALL clear `deletedAt` and return it to its folder.
- LIB-AC-08 (unit) WHEN `purgeDeleted(before:)` runs on launch and daily THE SYSTEM SHALL permanently remove items deleted longer than the retention period (default 30 days, configurable).
- LIB-AC-09 (UI) WHEN the user chooses permanent delete THE SYSTEM SHALL ask for confirmation and then purge transcript, segments and library-owned media.
- LIB-AC-10 (UI) WHEN referenced media cannot be resolved THE SYSTEM SHALL show a "missing media" state with a Relink action that updates the bookmark; the transcript SHALL remain viewable.
- LIB-AC-11 (unit) WHEN a transcript is created THE SYSTEM SHALL auto-title from the filename, or from meeting app + time, and allow editing.
- LIB-AC-12 (integration) THE SYSTEM SHALL store meeting recordings in the library and SHALL never delete user-referenced original files.
- LIB-AC-13 (UI) THE SYSTEM SHALL show a storage breakdown (library, models, recordings, caches), allow clearing caches and changing the library location (with move/confirm).
- LIB-AC-14 (integration) WHEN segments are written incrementally and the process is killed THE SYSTEM SHALL retain all committed segments (crash-safe, WAL).
- LIB-AC-15 (unit) THE SYSTEM SHALL tokenise Sinhala so that searching a Sinhala word matches its occurrences (FTS5 tokenizer verified).

## Edge cases
Empty library state with import prompts; no search results state with filter reset; DB migration failure shows recovery (backup restored, not silent data loss); folder deleted → items move to Library root.

## Non-functional
Library load < 500 ms @ 5,000; memory O(visible rows); migrations tested up/forward with fixtures.
