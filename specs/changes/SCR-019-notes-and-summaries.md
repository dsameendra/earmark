# SCR-019: Notes and summaries
Status: Applied (1.2.0).
Reason: Earmark 1.2.0 "Workspace" (specs/releases/workspace-plan.md).
Change: `TranscriptNotes` (Markdown), `NotesVersion`, `SummaryStyle`, `NotesRepository` (including `moveWorkspace` for the live-draft to final-transcript hand-over).
Persistence: New tables `transcriptNotes`, `notesVersion`, plus FTS so Library search finds notes. Summarise writes a version before replacing the page. Migration `v4-workspace` is append-only; downgrading after it is unsupported.
