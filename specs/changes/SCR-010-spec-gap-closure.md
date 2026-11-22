# SCR-010: Spec-gap closure (manual ignore flag, copy into library, per-file overrides, storage)

Status: Authorized by the product owner as part of the code-review follow-up, 2026-11-22. Source: "Spec gaps" 1, 3, 4 and 5 in `specs/qa/code-review-2026-11-22.md`.

## Contract and schema changes

1. **`Segment.ignoreFlagIsManual: Bool`** (AppCore, default `false`; `init(from:)` tolerates data without the key). It is `true` once the user sets `isIgnored` by hand, in either direction. Re-deriving never touches such segments (IGN-AC-05). Merge keeps the flag if either side had it.
2. **Persistence migration `v2-segment-manual-ignore`**: `ALTER TABLE segment ADD COLUMN ignoreFlagIsManual INTEGER NOT NULL DEFAULT 0`. Append-only; the existing pre-migration backup applies. Test: a v1-shaped file upgrades with its rows intact and the flag `false`.
3. **`JobSettings.copyIntoLibrary: Bool`** (AppCore, default `false`; custom decoder so journaled jobs still load). No table change: settings are stored as JSON.
4. **`JobQueue.enqueue(requests: [FileJobRequest], recursive:)`** (AppCore). `FileJobRequest` pairs a file or folder with its own `JobSettings`. A default extension groups consecutive requests with identical settings, so existing adapters keep compiling. `PersistentJobQueue` implements it natively as one batch; `enqueue(files:settings:recursive:)` now forwards to it.
5. **`JobQueueServices.libraryRoot`** (Jobs, optional closure): the folder that owns copied media.

No other AppCore/Persistence shape changes.

## Behaviour

- **IGN-AC-05.** `IgnoreRederiver` (Processing) recomputes only `isIgnored` for every stored transcript (including Recently Deleted) with the current rules, skipping manual flags and empty segments; text is never rewritten. Settings > Ignored Segments runs it after any rule add, delete, enable/disable, edit, import, undo, restore-defaults, reset, and after the hallucination toggle or thresholds change; overlapping changes queue one extra pass. The result is shown under the list. To make this consistent, file jobs now honour the Settings hallucination toggle and thresholds (previously hard-coded on with default thresholds, against IGN's "off by default"). The editor's Ignore / Stop Ignoring sets the manual flag.
- **FILE-AC-16.** "Copy into library" in the batch sheet. The job copies the file to `<library root>/Media/<asset id>/<name>`, stores `libraryRelativePath`, sets `isOwnedByLibrary`, and drops the bookmark. A failed copy (or no library root) falls back to the bookmark with a status note.
- **FILE-AC-04.** Each file or folder in the batch sheet has "Customize…" for language (batch, detect, or one language), model, speakers, translation and auto-export; "Same as batch" inherits. A model that cannot handle a file's language resets to Auto. Overrides travel as per-request settings inside one batch.
- **LIB-AC-13.** Settings > Storage shows Library (copied media plus the database), Models, Recordings, Caches and Total, measured off the main actor; Clear Caches refreshes it. "Change…" picks a folder, validates it (exists, writable, not inside the current location, no non-empty `Library`/`Meetings` already there), shows size and destination in a confirmation, then moves `Library/` and `Meetings/` (rolling back a partial move) and stores `storage.libraryLocation`. "Use Default Location" goes back through the same flow. Library-owned media resolves against `LibraryLocation.currentLibraryRoot`, updated at launch and after a move.

## Remainder (not done, by design)

- The SQLite database stays in `Application Support/Earmark`; moving an open WAL database safely needs a quiesce-and-reopen step in the composition root. The UI says so.
- The running `MeetingSessionController` keeps its recordings root until relaunch; the post-move notice says so. A separate Meetings folder chosen in Settings > Meetings is not moved.
- Per-file **multilingual** override (several languages) is not offered; single language and detect are. Batch-level multilingual still works for files that inherit.
- Per-file overrides are per dropped item; files inside a dropped folder share that folder's override.
- `clearCaches` still only deletes `~/Library/Caches/<subsystem>`; nothing writes there yet (review item 1, unchanged).
- Purging a transcript removes the library-owned media row but not its copied file (review B2 / LIB-AC-09); copied files are now more common, so that cleanup should follow.
- Existing meeting assets store `libraryRelativePath` as a bare file name that does not resolve under the library root (pre-existing; not changed here).
- The app target was not built (no full `xcodebuild`); `App/AppEnvironment.swift` changes are two small closures that only use symbols covered by package tests.

## Evidence

Serial `swift test`: Persistence 39, Processing 45, Jobs 47, Features 338, AppCore 9, Meetings 86 tests passed.
