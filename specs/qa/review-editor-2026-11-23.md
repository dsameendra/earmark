# Editor / playback review, 2026-11-23

Scope: `git diff 84365c5..HEAD` for FeatureEditor, DesignSystem WaveformView/WaveformMath, PlaybackCenter, MiniPlayer, player window sizing, export model and sheet.
Tests: `Packages/Features/Tests/FeaturesTests/EditorReviewTests.swift`, `Packages/Export/Tests/ExportTests/FileNameTests.swift`.

## Fixed

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| 1 | High | Find > Replace and Replace All changed segment text without setting `isUserEdited`, so a later non-destructive Re-transcribe overwrote the replaced text. | `TranscriptEditorModel.apply(changeSet:)` flags text-changing replacements; undo restores the flag (it lives in the before/after pair). |
| 2 | High | Export file names were cut at 120 characters, not bytes. A Sinhala, CJK or emoji title over about 85 characters exceeded the 255-byte file-system limit and the write failed. | `FileNames.sanitize` also caps at 200 UTF-8 bytes on a character boundary; `FileNames` made public. |
| 3 | Medium | Save panel always proposed `Transcript.<ext>` although the title was available. | `EditorExportModel.suggestedFileName` (sanitised title + extension). |
| 4 | Medium | View > Zoom In/Out/Actual Size acted on the editor's private pre-load `PlaybackModel.zoom`. After the shared session replaced it, the menu did nothing for the dock waveform (the registry was activated in `onAppear`, before `load()` swapped the model). | Re-activate on `model.playback` identity change and on dock waveform hover. |
| 5 | Medium | Make Player Larger/Smaller from the menu bar with the mouse was always disabled for the mini-player: hover-exit deactivated it before the menu opened. | Mini-player stays the target after hover ends (deactivates on disappear). |
| 6 | Medium | Two quick Start presses (or a Start while a re-run was already starting) captured the locked state as "read-only to restore", leaving the editor read-only for good. Also the editor was only locked after `flush()` suspended. | `rerun` is guarded by `isRerunning`/`rerunStarting`; the lock is applied before the flush. |
| 7 | Low | Pressing play at the very end of the media did nothing (player pauses at item end). | `PlaybackModel.togglePlay` seeks to 0 first when at the end. |
| 8 | Low | In bilingual/translated find, the "current match" colour was painted on a translation range whenever an original-text match shared the same offsets. | `FindReplaceModel.currentTranslationRange(in:)` checks the match field. |
| 9 | Low | A saved popup-player frame from a disconnected display, or bigger than the current screen, could restore off-screen. | `PlayerWindowSizing.restored(_:screens:)` applied after `setFrameUsingName`. |
| 10 | Low | `rerunWatcher` was not cancelled in `deinit` (kept an event stream loop alive until the next job event). | Cancelled in `deinit`. |

## UX changes

- Re-transcribe popover: Start now explains why it is disabled (no media, read-only, nothing selected, nothing chosen, no language).
- While a re-run runs, the editor shows a slim banner with progress and Cancel, since the editor is read-only and the popover can be closed.

## Reviewed, no bug found

- `PeakPyramid.peak(in:)` alignment and partial blocks, empty and 1-bucket data; `WaveformViewport` clamps at zoom 1 and 16; zero-length duration guards in `time(atX:)`/`x(forTime:)`; ribbon layout on overlapping segments.
- Waveform cache key (asset id + mtime + size + version), cancellation in `extract` per buffer, one decode per session (`waveformRequested`), 10 h media is capped at 200 000 buckets.
- `PlaybackCenter` generation tickets: concurrent `open` for different transcripts leaves one live player; deletion paths call `stop(transcriptID:)`; `captureDidStart` is wired for recording and dictation.
- Keyboard capture respects editable text views (find bar, inline edit), sheets, popovers and modal windows.
- Stale-translation baseline logic handles undo and redo. Speaker rename reaches the export document (existing test).
- Canvas drawing and `DragGesture` share one unmirrored coordinate space, so RTL layout does not flip scrubbing.

## Not fixed (noted)

- `MediaLocator.url` calls `startAccessingSecurityScopedResource()` per resolve without a matching stop (small leak per open).
- `prepareShareFile` leaves `EarmarkShare-*` temp folders behind.
- Transport and mini-player "Playback position" label is read together with the waveform's label of the same name; the raw `%.2f` accessibility value is relied on by UI tests, so it was left alone. Needs a UI-test update to speak a clock instead.
- Space activates play even when a SwiftUI/AppKit button has keyboard focus (`PlaybackKeyboardFocus` allows `NSButton`), which conflicts with Full Keyboard Access activation.
- A single `PlayerWindowController` assumed: a second controller would fail `setFrameAutosaveName` (same name).
- Playing while a capture is already running is not blocked (only the start of capture pauses playback).
- Overlapping concurrent seeks in `AVPlayerEngine.seek` (drag scrubbing) can resume playback before the last seek lands; harmless in practice.

## Test results

- Export: 24 tests passed.
- DesignSystem: 87 tests passed.
- Features: 493 tests passed (7 new).
- No UI tests run (per instructions).
