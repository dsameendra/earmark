# SCR-018: Folders and pins
Status: Applied (1.2.0).
Reason: Earmark 1.2.0 "Workspace" (specs/releases/workspace-plan.md).
Change: `Folder` entity and `FolderRepository`; `Transcript.pinOrder`; `LibraryQuery.pinnedOnly`. Folders move from the `library.folders` setting into a `folder` table (migration v4). `parentID` is stored for later nesting; 1.2.0 uses one level.
Persistence: Optional new field on `Transcript` (decodes from older JSON). Folders migrate with their order; nothing is lost. Migration `v4-workspace` is append-only; downgrading after it is unsupported.
