# SCR-004: Job has no meeting link; segment revisions have no home
Status: Proposed. Not applied; both are worked around in the app.

## Job.meetingID
Reason: a `.finalizeMeeting` job identifies its meeting only through `Job.input` (the recording folder, whose `meeting.json` carries the `MeetingID`) and `Job.transcriptID` (the live transcript). The queue UI cannot show "Zoom meeting, finalizing" or link the job to the Meetings list without reading the folder (found by T23).
Current workaround: `MeetingFinalizer.makeJob(directory:liveTranscriptID:)` sets `input` and `transcriptID`; the job title in notifications comes from the handler result ("Zoom meeting").
Proposed change: additive `public var meetingID: MeetingID?` on `Job` (defaulted init parameter), stored in the jobs table JSON. `MeetingSessionController` and `RecordingRecovery` consumers set it.

## Segment revisions (LANG-AC-08)
Reason: "keep a revision" when a segment is re-transcribed. `Transcript.revisionOf` exists but means a whole-transcript copy; there is no per-segment history.
Current workaround: the Editor stores `[SegmentRevision]` (old text and language, time) per transcript in the `SettingsStore` under `editor.segmentRevisions.<transcriptID>`, and the replacement is one undo step. The revisions are not exported and not shown in a history UI yet.
Proposed change: a `SegmentRevision` table in Persistence (segment id, text, words, language, replaced at, reason) with a repository method on `TranscriptRepository`, or a `revisions: [SegmentRevision]` field on `Segment` kept out of the hot path.
