# Workspace: folders, pinned items, notes, summaries, slides and chat

Status: **approved by the owner and implemented in Earmark 1.2.0.** Departures from the plan: one `FeatureWorkspace` module holds Notes, Chat and Files instead of three; the stage sits above the tabs (as the video does today) rather than beside them; the notes editor is a live-styled Markdown editor, not a WYSIWYG one.
Design mock-ups: `specs/design/workspace/mockups.html` (also published as an artifact).

## 1. Goal

Earmark stops being "a transcriber" and becomes the one place for meetings and lectures:

- keep recordings organised (folders, pinned folders and transcripts in the sidebar, grouping in the Library);
- write notes by hand next to the transcript;
- turn a transcript (and any notes, slides or PDFs attached to it) into a structured summary, on this Mac;
- attach slides or PDFs, view them instead of the video, and summarise them;
- ask questions about a transcript and its attachments and get answers grounded in them, with sources.

Everything stays 100% local: Apple Foundation Models run on device, no cloud, no telemetry, no Private Cloud Compute.

## 2. What was verified before planning

Apple's on-device model was exercised on this Mac (macOS 27.2, Apple Intelligence available) with two throw-away evaluations. They were synthetic English tests with planted facts, so they show the approach works, not that every real recording will.

| Check | Result |
| --- | --- |
| Availability / languages | `available`; da, de, en, es, fr, it, ja, ko, nb, nl, pt, sv, tr, vi, zh. **No Sinhala** and many other languages Earmark transcribes. |
| Context window | **8192 tokens** (`SystemLanguageModel.contextSize`, macOS 26.4+; older 26.x are about 4096). About 5 characters per token: a 42,500-character document (roughly 40 to 50 minutes of speech) already overflowed (8,795 tokens) (`exceededContextWindowSize`). |
| Q&A on a 13-line meeting (11 questions, 3 unanswerable) | 11/11 correct, **0 invented answers** (it answered "Not stated in the transcript"), 0.8 s per answer. |
| Structured summary of that meeting (`@Generable`) | All three action items correct with owners and days; decisions correct. **Weaknesses:** the overview was vague, one decision was listed twice, and two stated facts (the backup-provider risk, the staging maintenance) were left out of the discussion points. |
| Citations written by the model | **Unreliable**: in 8 answers, 3 quoted the wrong timestamp. |
| Q&A on a 42,500-character lecture, using 4 retrieved excerpts (5 questions, 1 unanswerable) | 5/5 correct, refusal correct. |
| Map-reduce summary of that lecture (6 chunks) | 5/5 planted dates and numbers kept exactly; 55 seconds. |

Consequences that shape the design:

1. **Long recordings must be summarised in stages** (chunks, then a merge). A 1-hour talk is about 4 chunks, a 3-hour lecture about 12. Expect roughly 1 to 4 minutes, shown with progress and Cancel.
2. **Chat must retrieve, not paste.** Each question pulls the few most relevant excerpts (plus summary and notes) into the prompt.
3. **Citations are computed by Earmark, never taken from the model's text.** Each answer shows the excerpts it was given as source chips (timestamp or slide number) that jump to that place.
4. **The summary prompt forces exhaustive extraction** (separate lists for decisions, actions, risks and dates) because free-form summaries drop details.
5. **Answers say "not stated" rather than guess.** The instruction, a source-scope control and an "Answered from" footer keep the user able to judge accuracy.
6. **Unsupported languages are blocked with a clear reason**, not attempted. Apple Intelligence off or still downloading is explained with a button to System Settings.
7. A repeatable **accuracy harness** (planted-fact documents, run on a machine with the model) ships with the feature and is run before release; hosted CI uses a fake generator.

## 3. Product design

### 3.1 Sidebar (rebuilt)

Order, top to bottom:

1. **Home, Queue, Meetings, Live** (unchanged, ⌘1 to ⌘4).
2. **Library**, followed by everything the user **pinned** (folders and individual transcripts), indented under it. Pinned folders show a count; pinned transcripts show a small type icon. Drag to reorder.
3. **Recently Deleted.**
4. **Speech model**: shrinks from the current card to one compact line (icon, short model name, status dot). The picker still opens as a popover.
5. **Settings**, as today.

Pinning: context menu (Pin to Sidebar), a pin button in the folder header and the transcript header, or drag a folder/transcript onto the sidebar. Keyboard: ⌘1 to ⌘6 select Home, Queue, Meetings, Live, Library, Recently Deleted (unchanged); ⌘⌥1 to ⌘⌥9 open pinned items.

### 3.2 Library: folders and grouping

- Folders become real, first-class objects: create, rename, colour, delete (items move to the Library root), pin. Drag items onto a folder, or use Move To. One level in this release (the schema carries a parent for later). Existing folders are migrated, no data is lost.
- Library root shows folders as a row of compact cards above the list; opening a folder shows its items with a breadcrumb.
- **Group by** (toolbar menu): None, Date (Today, This week, This month, Older), Folder, Type (Meeting, File, Live, Dictation), Language, Tag. Group headers are collapsible and remember their state.
- Library search also searches notes, summaries and attachment text.

### 3.3 The transcript page (redesigned, existing behaviour kept)

Everything that exists today stays: transcript editing, speakers, translation, re-transcribe, bookmarks, find and replace, view options, export, the video/audio player, the waveform and transport bar, and the inspector.

What changes:

- **Header**: editable title, folder chip (click to move), pin, source and date, duration, language, and an **Ask / Summarise** entry.
- **Stage** (the player area) gets a switch: **Video or audio / Slides**. With slides attached the user can view them instead of the video, page with the arrow keys or the thumbnail strip, and optionally **link slides to time** (press "Slide changes here" while playing; playback then follows the deck). The mini-player keeps working.
- **Content area** becomes four tabs: **Transcript, Notes, Chat, Files**. Transcript is today's list, unchanged and still the default. In a wide window with the inspector collapsed, Notes or Chat can sit beside the Transcript (split view); on narrow windows they replace it.
- **Notes**: a rich-text page the user writes by hand (headings, bold, italic, bullet and numbered lists, checkboxes, links). "Insert timestamp" (⌘⇧T) adds a link to the current playback time that jumps back to it. Notes autosave. Version history keeps earlier versions.
- **Summarise** (button in Notes, also in the header): shows a style (Meeting, Lecture, General), what to include (Transcript, My notes, Slides and files), then generates a structured summary into the Notes page:
  - Meeting: **Summary, Discussion points, Decisions, Action items** (owner and date only when stated), **Risks and open questions**.
  - Lecture: **Summary, Key concepts, Definitions and formulas, Examples, Announcements and deadlines, Questions to review**.
  - **Hand-written notes are an input**: the model is told to keep their facts and wording where they are accurate and to treat them as the user's emphasis. The result **replaces the page content, as requested, but nothing is lost**: the previous page is saved as a version and an "Undo summary" banner stays until dismissed. Running Summarise again uses the current page (including later edits) plus the transcript.
  - Long recordings run in stages with a progress bar, a Cancel button and a "Using Apple Intelligence on this Mac" line.
- **Chat**: a conversation about this transcript. A **Sources** control sets what answers may use: *Everything* (transcript, summary, notes, attachments) or *Summary and notes only*. Replies stream, end with source chips that jump to the transcript time or slide, and say "Not stated in the transcript" instead of guessing. Suggested questions adapt to meetings ("What were the action items?") and lectures ("What are the key concepts?", "Quiz me on this lecture"). Conversation is saved per transcript and can be cleared.
- **Files**: attached slides and PDFs. Each file shows page count, a **Summarise** action (per-file summary, stored with the file), and "Used in chat and summaries" toggle. Slides (a deck used by the Slides stage) and reference documents are the same mechanism with different roles.

### 3.4 Attachments: PDFs and slides

- Formats in this release: **PDF** and **images** (PNG, JPEG, HEIC). PDF text comes from PDFKit; pages with no text (scans, picture-only slides) go through on-device Vision text recognition. Keynote and PowerPoint cannot be read by macOS without those apps, so the Files tab says "Export as PDF first" with a short how-to (decision 5).
- Summarising a file: per-page text, chunked and merged like a transcript, producing Summary, Key points and, for slides, a per-slide one-liner. Questions about a file use the same retrieval, with the **page number** as the source chip.
- Chat can use a transcript and its files together ("What does slide 12 say about X, and what did the speaker add?").

### 3.5 Settings

New **Intelligence** pane (placed after Models):

- Status row: "Apple Intelligence is available / off / downloading / not supported on this Mac", with **Open System Settings**.
- Default summary style (Meeting, Lecture, Match the transcript type).
- Summary language (Same as transcript, App language).
- "Summarise automatically when a meeting finishes" (off by default).
- "Include my notes" and "Include attached files" defaults for Summarise and Chat.
- Keep chat history (On by default); Clear all chats.

Library settings gain: default grouping, show folders row. General gains: "Show pinned items in the sidebar" (on).

### 3.6 During a live meeting or recording (added at the owner's request)

While a meeting is being transcribed or recorded, the same redesigned page is available for it, not only after it ends:

- **Open it from** the Meetings page (the current-meeting card gets "Open workspace"), the sidebar recording row, and the menu bar.
- **Notes:** write by hand at any time. Autosaved.
- **Files:** add slides or PDFs at any time and page through them; "Slide changes here" links slides to the live clock.
- **Chat:** ask about what was said so far. Each question retrieves from the transcript as it exists at that moment (re-read on every question, so new speech is included) plus notes and files. A line under the box says "Up to 14:32 of the live transcript".
- **Transcript tab:** follows the live text (auto-scroll with a "Jump to latest" pill when the user has scrolled away). Editing is read-only until the meeting ends, as today.
- **Summarise is disabled** with the reason "Available when the meeting ends and the full transcript is ready". It enables when the final transcript has been produced (the Queue shows the finalisation job).
- **Hand-over:** notes, files, slide links and chat are stored on the live draft and **move to the final transcript** when finalisation creates it, so nothing typed during the call is lost (tested, including a call that is recorded, a transcribe-only call and a crash recovery).
- Works for every meeting app Earmark supports (Zoom, Teams, Meet, Discord, browser calls) and for plain Live captions sessions.

### 3.7 Export and search

Notes and summaries can be included in Export (TXT, Markdown, DOCX, PDF) behind two toggles, off by default so existing export presets behave as before.

## 4. Architecture

- **New package `Intelligence`** (depends on `AppCore` only): availability, `TextGenerating` seam over `FoundationModels` (real) and a scripted fake (tests, CI, UI tests), `Summarizer` (chunking, map-reduce, templates), `Retriever` (lexical BM25 over chunks, with on-device sentence embeddings where `NaturalLanguage` supports the language), `ChatEngine`, `DocumentTextExtractor` (PDFKit and Vision). Strict Swift 6; every FoundationModels symbol behind `#available(macOS 26, *)` and `#if canImport(FoundationModels)`; compiles on Xcode 26 and 27.
- **Dependency boundary**: Features never import `Intelligence`; they use seams in `FeatureSupport` (`SummarizationServicing`, `ChatServicing`, `AttachmentServicing`), composed in `App`, the same pattern as `MeetingScanning`.
- **New feature modules** `FeatureNotes`, `FeatureChat`, `FeatureAttachments`; `FeatureLibrary`, `FeatureShell` and `FeatureEditor` are extended. `scripts/check-dependency-boundaries` is updated for the new edges.
- **Contracts (AppCore is frozen, so numbered change requests):**
  - SCR-018 Folders and pins: `Folder` entity (id, name, colour, parent, isPinned, pinOrder), `Transcript.isPinned` / `pinOrder`, `FolderRepository`.
  - SCR-019 Notes and summaries: `TranscriptNotes` (rich text stored as Markdown, updatedAt), `NotesVersion`, summary metadata (style, source, generatedAt).
  - SCR-020 Attachments: `Attachment` (transcript, role slides/reference, file, page count, extracted text per page, summary).
  - SCR-021 Intelligence seams and chat messages: `ChatMessage` (role, text, sources), availability and error types.
- **Persistence**: one migration adds `folder`, `transcriptNotes`, `notesVersion`, `attachment`, `attachmentPage`, `chatMessage` and FTS tables for notes and attachment text, and moves `libraryFolders` out of settings into `folder`. The existing pre-migration backup is kept. **Downgrading after this release is unsupported** and the release notes say so.
- **Live and final transcripts**: a meeting's notes, slides and chat attach to the meeting. When finalisation creates the final transcript from the live draft, attachments move to the final transcript (tested).
- **Files**: attachments are copied into the library (`Attachments/<transcriptID>/…`) so moving the original does not break them; deleting a transcript moves them to Recently Deleted with it.

## 5. Quality, accuracy and safety

- **Fake generator everywhere in CI**; real-model tests are skipped when the model is unavailable (hosted runners).
- **Accuracy harness** (`scripts/eval-intelligence`): synthetic meeting and lecture documents with planted facts, unanswerable questions and long inputs; reports fact recall, invented-fact rate, refusal correctness, latency and chunk counts. Release gate: recall of planted dates, numbers and owners at least 90%, no invented answer on unanswerable questions in the standard set, run on the release Mac and recorded in `specs/qa/`.
- **Guardrails**: handled `guardrailViolation` and `exceededContextWindowSize` errors (retry a chunk smaller, skip with a visible note, never fail silently). Output is clearly labelled "Generated on this Mac. Check important details against the transcript."
- **Accessibility**: every control has an identifier; tabs, chat list and the slide viewer are keyboard operable and VoiceOver labelled; streaming text announces completion, not every token; Reduce Motion, Increase Contrast and Reduce Transparency respected; DesignSystem tokens only; at most three glass layers per screen.
- **Unit tests** for chunking, templates, retrieval ranking, citation mapping, notes round-trip (rich text to Markdown and back), version history, migration (settings folders to table), pinning order, grouping, attachment extraction, finalisation hand-over (notes, files, links and chat), live-transcript retrieval, Summarise gating. **UI tests** (with `-EarmarkTestIntelligence`; including the live-meeting flow) for the sidebar, folder drag, grouping, Notes, Summarise with undo, Slides stage, Chat with sources, Settings pane.

## 6. Phases (each ends with tests green and a pushed PR)

| Phase | Scope |
| --- | --- |
| 0 | Approval, SCR-018 to SCR-021, schema and migration, folder migration. |
| 1 | Folders, pinned items, sidebar rebuild (compact model chip), Library folders row and Group by. |
| 2 | Transcript page shell: header, tabs, Notes editor with versions and timestamp links, export and search. |
| 3 | `Intelligence` package, availability, Summariser with templates, Summarise UI, accuracy harness. |
| 4 | Attachments: import, extraction (PDFKit, Vision), Files tab, Slides stage, time links, per-file summaries. |
| 5 | Chat: retrieval, source scope, streaming, source chips, saved conversations. |
| 6 | Live-meeting workspace (open from Meetings, sidebar and menu bar; notes, files and chat against the live transcript; Summarise gated until the final transcript exists; hand-over to the final transcript), Settings pane, docs, website, release. |

## 7. Risks

- **Scope.** This is a minor-version feature set. See decision 1.
- **Model quality varies by language and length.** Mitigated by retrieval, staged summaries, "not stated" answers, source chips and the harness; some languages will be unavailable.
- **Speed.** Long lectures take minutes to summarise; always cancellable, always in the background (the Queue shows it).
- **Rich-text editing.** SwiftUI rich text with a Markdown round trip is the riskiest UI piece; the supported set is deliberately small (headings, bold, italic, lists, checkboxes, links).
- **Apple Intelligence absent** on some Macs. The feature degrades to a clear explanation; notes, folders, pins and slides still work without it.
- **Downgrade** after the migration is unsupported.

## 8. Decisions needed from the owner

1. **Release number.** The 1.1.3 fixes (single transcript, duplicate cards, naming) are finished except for the last CI/update-test cycle. Recommendation: **ship them as 1.1.3 now and release this work as 1.2.0**, because it adds a database migration (no downgrade) and is much larger than a patch. The parked multitalker plan then becomes 1.3.0. If you prefer one release, it would be 1.1.3 with all of this, later.
2. **Notes replacement.** Plan: Summarise replaces the page but keeps an undo and version history. Alternative: Summarise writes below your notes. (Recommended: the plan above.)
3. **Folders**: one level now, nesting later (recommended), or nested from the start.
4. **Chat scope**: per transcript now (recommended); chat across a folder or the whole Library as a later phase.
5. **Slides formats: DECIDED by the owner. PDF and images only.** Users convert PowerPoint or Keynote to PDF first (the Files tab says how). No PPTX or Keynote reader in this release.
6. **Standalone documents**: a PDF can only be attached to a transcript in this release (recommended). The alternative is PDFs as their own Library items to summarise and chat with.
7. **Auto-summarise after a meeting**: off by default (recommended).
