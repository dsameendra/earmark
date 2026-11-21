# SCR-001: Add speaker filter to LibraryQuery
Status: Approved (orchestrator), to apply with the Library UI task (T11)
Reason: LIB spec requires filtering by speakers; `LibraryQuery` lacks a field (found by T02).
Change: additive `public var speakerNames: Set<String> = []` in `AppCore/Persistence.swift`; Persistence filters on `Transcript.speakers` names. Source-compatible (defaulted init param).
Also tracked: purge must delete library-owned media rows/files at the service layer (T02 risk); media-missing placeholder ID mapping (T08).
