# Changelog

Releases are listed newest first. The website carries the same history: https://dsameendra.github.io/earmark/changelog.html

## 1.1.3

### Fixes
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
