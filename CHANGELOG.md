# Changelog

Releases are listed newest first. The website carries the same history: https://dsameendra.github.io/earmark/changelog.html

## 1.2.1

### Performance and fluidity
- **Fixes a freeze on the transcript page.** The whole page (toolbar, menus, transcript) was being redrawn many times a second while a recording played, and switching to Notes, Chat or Files with slides showing rebuilt the slide stage each time. Both are fixed, so opening Chat or Files after leaving a transcript no longer hangs the app.
- **Smoother playback and editing.** The waveform ribbon, the slide thumbnails and the playhead no longer redo their work on every tick. The playhead redraws at 30 frames a second, and long transcripts, Notes and the Live screen stay responsive.
- **Faster Notes.** Typing and moving the cursor no longer restyle the whole page or recompile the formatting rules.
- **Faster Library.** Grouping by date no longer repeats the calendar work for every transcript.
- **Live and Chat.** The input meter on the Live screen and the streaming answer in Chat now redraw only themselves.
- **Tidier layout.** Chat's footnote is no longer cut off, the Library toolbar keeps Select visible in narrow windows, the filter row keeps Clear Filters in view, the sidebar model chip shows its name, and the Files card, folder cards and Files header have consistent spacing.
- **Safer actions.** Clearing a chat, removing an attached file and clearing slide timings now ask first. Reduce Motion is respected when the chat and thumbnails scroll.

## 1.2.0

### Workspace: notes, summaries, slides, chat and folders
- **Folders and pinned items.** Folders are now real: create, rename, give them a named colour (Ember, Teal, Indigo, Amber, Plum, Slate, Blue, Crimson), drag transcripts onto them, and pin a folder or a transcript to keep it under Library in the sidebar. Drag a transcript or a folder onto the sidebar to pin it, drag pinned rows to reorder them, drop a transcript on Library to take it out of its folder or on Recently Deleted to remove it.
- **A new transcript page.** Every transcript now has Transcript, Notes, Chat and Files tabs on the right, with the video or the slides on the left (drag the divider to resize it). Summarise is the one orange button; Export is an ordinary button. The side panel is gone: speakers are in Speakers, and bookmarks, view options, ignored segments and Re-transcribe are in the More menu, so the transcript has the full width.
- **Notes.** Write notes by hand next to the transcript in Markdown: type # for a title, ** for bold, - for a list, - [ ] for a checklist. Lines show formatted as soon as you move off them, Return continues a list, and timestamps jump the recording. Summaries are formatted the same way. Notes autosave and keep a version history.
- **Library.** One click opens a transcript. Select turns on checkmarks (list or grid): pick items, then Delete, Move to folder or Pin, with Undo after a delete. Grouping now works in the grid too, and Date groups read Today, Yesterday, This week, Last week, This month, Last month, then by month and year.
- **Summaries on your Mac.** Summarise writes a structured summary into the notes with Apple Intelligence: for meetings, discussion points, decisions, action items and risks; for lectures, key concepts, definitions, deadlines and review questions. Your own notes are read as part of it, the page as it was is kept in History, and Undo is one click. Nothing leaves your Mac.
- **Slides and files.** Attach a PDF or images, view the slides instead of the video, page with the arrow keys, link slides to moments in the recording, and summarise each file. For PowerPoint or Keynote, export to PDF first.
- **Chat.** Ask questions about a recording, its notes, summary and attached files. Answers say where they came from, with sources you can click, and say so when something is not stated. Choose Everything or Summary and notes only.
- **During a meeting.** While a meeting is being transcribed or recorded you can open Notes and chat from the Meetings page or the menu bar, write notes, add slides and ask about what was said so far. Summarise unlocks when the meeting ends. Everything you add moves to the final transcript.
- **Menu bar and Settings.** Detect meetings is in the menu bar. A new Intelligence pane in Settings shows whether Apple Intelligence is ready and sets summary style, language, automatic summaries and chat history.
- Note: after this update an older version of Earmark cannot open your library, so do not downgrade. Summaries and chat need a Mac with Apple Intelligence turned on and a language it supports (Sinhala and some others are not supported yet); everything else works without it.

## 1.1.3

### Fixes
- A call is now listed once on the Meetings page. A Google Meet call used to appear three times: as a detected-meeting banner, as a current-meeting card and under Available now. Names read "Google Meet call detected" and "Discord meeting detected" instead of "Meet meeting detected".
- Each meeting now appears once. Recording or transcribing a call used to leave two entries in the Library, a "Live captions" draft and the meeting itself. The draft is no longer listed or searched once the meeting transcript exists, including for meetings you already have.
- The menu bar says "Discord meeting detected", "Google Meet call detected" and so on instead of calling everything Zoom or Teams.

## 1.1.2

### Google Meet, Discord and Detect meetings
- Google Meet calls in Chrome, Edge, Brave, Arc, Vivaldi, Opera and Firefox are recognised and can be transcribed or recorded, with no Google account, sign-in or browser extension. Earmark only reads whether the browser is using your microphone and the title of its windows, which needs the Accessibility permission Dictation already asks for.
- Discord voice and video calls are supported like Zoom and Teams.
- A new Detect meetings button on the Meetings page looks again right now and lists every call that can be transcribed, including a browser call Earmark could not tie to a service (Safari included). Each row has Transcribe and Transcribe and record. If nothing is found it says what it looked at.
- One Detection menu on the Meetings page sets what Earmark does for each of Zoom, Teams, Meet and Discord.
- Meetings and recordings are named after the service: "Discord meeting", "Google Meet", "Browser call" and so on, in the transcript title and in the recording's folder name. Discord calls were wrongly called Teams.
- A call that is only transcribed (not recorded) is now saved as a meeting under the same name, not as an anonymous live-captions session.
- The final transcript of a meeting keeps the language that live captions already heard. With language detection on, a short English call could come out in the wrong script.
- Detect meetings is also in the menu bar.
- In Meetings, clicking anywhere on a past meeting opens its transcript.
- Note: after recording a Meet or Discord meeting, older versions of Earmark cannot open that meeting, so do not downgrade.

## 1.1.1

### Fixes and polish
- The last lines of a transcript can now be scrolled into view. In the video layout they used to sit behind the player bar.
- Speakers, Translate, Re-transcribe, Bookmarks, View options and the inspector cards open their panel right next to the button you used, inside the window. They no longer open somewhere else in the app.
- Re-transcribe keeps its Start button in view while the options scroll.
- Home now has the same margins as Queue, Meetings, Live and Library.
- Buttons on the orange accent are readable in dark mode.
- Links use Earmark's accent colour instead of system blue.
- Speaker colours match between the inspector, the transcript and the Library.
- Replacements has visible text fields and clear option checkboxes.
- The Export sheet opens on its main action, not inside the preset field.
- Smaller touches: the Dictation card explains how to set it up, colour swatches are easier to hit, Storage shows 0 KB instead of Zero KB, the Settings window no longer shows a bar at the top, and About Earmark moved to the Help menu.

## 1.1.0

### New speech models
- **Qwen3-ASR 0.6B and 1.7B** for 30 languages, alongside the unchanged Sinhala specialist.
- **Parakeet** v3, Ultra and Redux (25 European languages, word timing). Redux compiles on first use, which can take several minutes once.
- **Parakeet EOU**: a small English streaming model that ends each utterance when you pause.
- **Nemotron 3.5 Streaming**: native live captions in 28 languages.
- **Voxtral Mini Realtime**: streaming captions and files in 13 languages (needs a larger Mac).
- **Cohere Transcribe**: file transcription in 14 languages.
- **Canary 1B v2**: file transcription in 25 European languages. Recognition only.

### New translation models
- **NLLB-200** now covers about 200 languages and scripts instead of six (experimental, non-commercial).
- **MADLAD-400** runs natively, for 27 languages including Sinhala.
- **OPUS direction packs** for English with German, French and Spanish, both ways.
- **Hy-MT2** (1.8B, 7B) and **TranslateGemma** (4B, 12B), offering only the directions that passed Earmark's quality checks: English with German, French and Spanish, and Japanese and Chinese into English (Hy-MT2 7B also English to Japanese). TranslateGemma requires accepting the Gemma terms.

### Live translation and routing
- Live has an independent **Translate captions** switch with source and target pickers and a readiness message.
- Your chosen translation engine is honored everywhere. Translation lag is bounded: stale partials are dropped, finals kept, and the original caption stays if translation fails.
- Apple Speech readiness is checked for the language you selected; Apple Translation packs are shown separately from speech assets.

### Models page
- A compact page with recommendations and installed models, plus a searchable **Add models** browser grouped by family showing languages, streaming mode, size, memory and licence.
- **Add from Hugging Face** accepts links to the exact reviewed checkpoints only, pinned to a fixed revision.
- Custom licences (Gemma, OpenMDW, NVIDIA Open Model) are named plainly and need your acknowledgement before download.
- Large models load one at a time; starting one releases idle ones.

### Known limits
- Most new models are experimental. Accuracy was checked on real recordings, mostly English, so quality in other languages varies.
- **Not included:** Seamless M4T v2 and overlapping-speech recognition (Multitalker). Neither has a reliable native Mac runtime or passed its quality bar; both are planned for a later release.
- Hy-MT2 and TranslateGemma do not offer English into Chinese (and only Hy-MT2 7B offers English into Japanese) because those directions did not pass the quality checks.
- Cohere and Canary have no live mode or word timing; Canary never translates speech.
- Physical 8 GB and 32 GB Macs have not been measured, and microphone, system-audio and meeting capture were not re-tested on the signed app for this release.

### Install
Requires macOS 26 or later on Apple silicon. Earmark is self-signed and **not notarized**: open the DMG, drag Earmark to Applications, then approve the first launch with **Open Anyway** in System Settings, Privacy and Security (or `xattr -dr com.apple.quarantine /Applications/Earmark.app`). Existing installations can update through Settings, General, Check for Updates.

## 1.0.1 (23 November 2026)

- Zoom and Teams policy menus update their labels and selected options immediately.
- Transcripts saved without audio or video show "No recording"; Relink is reserved for recordings that went missing.
- Removed the unwanted sidebar toggle and its empty background from the main window and Settings, including after reopening.
- Compatibility fixes for building with the macOS 26 SDK.

## 1.0.0 (23 November 2026)

Private, on-device transcription for Mac: files, live captions, dictation and meetings. Batches with language, model and speaker choices; live captions overlay; dictation; Zoom and Teams capture (ask first by default); a waveform editor with original, translated and bilingual views; speaker identification; Sinhala (experimental); export to TXT, Markdown, DOCX, PDF, JSON, CSV, SRT and VTT.
