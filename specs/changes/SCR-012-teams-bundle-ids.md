# SCR-012: MeetingApp.teams lists both Teams bundle IDs
Status: Applied (QA triage A, 2026-11-22).
Reason: `MeetingApp.teams.bundleIDs` held only the new Teams ID (`com.microsoft.teams2`), while `MeetingAppSignature.defaults` matches the prefix `com.microsoft.teams` (new, classic and helper processes such as `...teams2.modulehost`). The two tables disagreed.
Change: `MeetingApp.teams.bundleIDs` is now `["com.microsoft.teams2", "com.microsoft.teams"]` (index 0 stays the primary, new Teams). No type or case changes. `MeetingAppSignature` gains optional `executableNames` (MSTeams) and `callHelperNames` (Zoom CptHost), and `AppAudioActivity` gains a defaulted `helperPresent`, all inside the Meetings package.
Impact: none for callers that use `bundleIDs[0]`; callers that iterate see one more ID.
