# Manual QA: visual, permission and hardware gates

Status (2026-11-22): **pending execution**. M8 implementation and M7 preparation tooling are present. The final serial package recheck and mock UI runner were pending at this documentation update. A running development app or a passing mock test does not establish the real behaviours below. Record the tested commit, app build/configuration, signing identity, macOS/hardware, relevant model versions, result and evidence for each check; mark unavailable environments as blocked rather than passed.

Use the real-service Debug app for capture/insertion checks. The `DebugUI` configuration and `-UseMocks` launch argument are for deterministic screen tests only. They must not be used as real capture evidence. Keep test recordings/transcripts separate from valuable data, especially for explicit deletion and crash-recovery checks.

## Build and automated evidence

1. Generate with `scripts/project.sh`; build/run the printed project in Xcode using scheme Earmark and Debug. It references the repository sources from the local cache, avoiding the cloud-synced generated-project stall. See the root README for command-line build/run instructions.
2. Run `scripts/check.sh unit`, `scripts/check.sh build` and `scripts/check.sh ui`. Save the reports under `~/Library/Caches/EarmarkBuild/reports` (or `EARMARK_REPORT_ROOT`). Report final executed counts, skips and failures; earlier handover counts are historical.
3. Review XCUITest screenshot attachments in the result bundle. The UI tests use a separate QA identity and mock services and do not request capture permissions or download weights. Check all routed screens, editor/export, narrow inspector, onboarding and Settings. A successful screenshot capture alone is not design approval.
4. Real native translation parity tests require a local model and explicit helper/model environment variables; follow `NativeRuntime/README.md`. A suite skipped without those inputs is not a real-model pass.

## M8 design and accessibility acceptance (T35–T40)

Compare to `specs/design/m8-mockups/png/` and `static/`, using the final-v1 handoff values. Placeholder titles, durations and sample copy need not match actual data.

- Capture Home, Queue, Library, Editor, Meetings, Live, Settings, Export and all five onboarding steps at **1440 × 900**, light and dark. Also cover empty, loading, error, Recently Deleted, translation and permission states. Confirm solid content surfaces, Ember primary action, recording red, clear sidebar selection and icon legibility.
- Resize to **960 × 600** and wide/full-screen. Verify scrollable sidebar/settings, four/two Home action columns, dropped Library columns, readable centred transcript, docked video resizing and a usable player. Below 1100 points verify the inspector toggle, dismissal/reopening and inspector actions that open speaker/bookmark editors. Verify Settings sections hidden by toolbar overflow remain reachable.
- Use keyboard navigation throughout: ⌘1–⌘6, ⌘K, ⌘F/⌥⌘F, editor undo/redo, playback shortcuts and export/cancel. Open both Bookmarks and View options from More. Confirm focus is visible and shortcuts do not insert into or steal focus from editing fields.
- Turn on Reduce Motion: selection/overlay/onboarding transitions and transcript reveal/auto-follow must avoid sliding/pulsing; the recording dot remains visible. Turn on Reduce Transparency and Increase Contrast separately and together: glass becomes its solid twin and controls remain distinct. Inspect both appearances.
- Run VoiceOver through sidebar, Library rows/cards, player, inspector, Settings, permission actions, onboarding and Export. Check control names, selected/disabled state, meaningful reading order and missing-media/recording announcements.
- Increase supported text/accessibility sizes and verify rows reflow, labels remain readable and sheets/toolbars can reach every control. Verify Sinhala shaping, line breaking and fallback in transcript, caption overlay and export preview.
- Record measured token contrast (4.5:1 normal text, 3:1 large text) in both appearances and Increase Contrast. Static token tests supplement, rather than replace, visual inspection of actual surfaces.
- Profile glass/scrolling and input on M1-class hardware, including the minimum-memory tier. Record frame timings against the 16 ms budget, responsiveness and memory during inference. Record before/after evidence for T40 and final performance evidence for T28; no target-hardware result is inferred from this development Mac.

## Onboarding, Library, editing and export

1. Settings → General → Show Welcome Again (and Help menu): complete all five steps, back/skip where offered, language selection, permission links, model recommendation/download consent and meeting consent. Close/reopen without losing saved preferences. Verify no download starts without an explicit choice.
2. Import a small audio and video file; verify Queue progress, cancellation/retry, Library arrival and Home Recent/Working updates. Change the preferred model and install/delete a model from Settings while Home stays open; Home and sidebar status should update.
3. Open a transcript, edit text/speaker/language, find/replace, ignore/show segments, bookmark and undo/redo. Reopen to verify persistence. Exercise playback seek, rate, video resize/detach/reattach and synchronized highlighting.
4. With a disposable imported file, make referenced media unavailable. Confirm visible Library warning and disabled playback with Relink; text stays editable. Relink the file and verify playback restores.
5. Export text, subtitles and one rich format; compare options and the first-six-segment preview. DOCX/PDF show a labelled text preview. Exercise Original/Translated/Bilingual export where available, preset save/apply, copy/share and cancellation. Verify exported files outside the app.
6. Soft-delete a disposable transcript, restore it and verify Recently Deleted retention copy. Permanently delete only disposable test data; confirm the destructive warning.

## Audio, meetings and crash recovery

- Settings → Audio: explicitly Test microphone, verify level changes, Stop, switch input and test again. Leave/close Settings while active and verify capture stops. Deny microphone access, follow the System Settings link, grant/retry. Disconnect or fail a selected device; verify the test reports/stops appropriately and can restart. Record route/default-device fallback separately for real Live/meeting capture.
- Zoom (`us.zoom.xos`): start a test call while Earmark runs. Confirm ask-first prompt and no recording before acceptance, decline/accept paths, persistent recording indication, two-track output and finalized Library transcript. Check optional video explicitly. End the call and confirm finalization and usable playback.
- Deny System Audio Recording and repeat: verify silent-denial/error recovery, with no misleading successful recording state. Grant and retry. Check notification permission denial does not block manual recording.
- Teams (`com.microsoft.teams2`) was not installed at handover. Install/use an authorized test client before claiming detection/tap support; otherwise record blocked. Check other configured meeting apps against their feature acceptance criteria.
- With only a disposable recording in progress, force-kill the app and relaunch. Verify recoverable fragments remain playable, recovery is offered and finalization preserves tracks/transcript. An ordinary stop is not a crash-safety test.
- Compare TCC re-prompts across ad-hoc and stable team-signed rebuilds. Record the actual identity used; Developer ID distribution permissions need their own signed-artifact check.

## Sinhala, translation, Live and dictation

- Download the Sinhala ASR model from Settings → Models after reviewing size/licence. Transcribe representative Sinhala read, conversational and code-mixed clips; verify engine selection, segment language routing and re-transcribe. Historical CER figures are not a pass on new test material.
- Translate a transcript into German/French through Apple Translation. Verify the system language-pack sheet, cancellation, offline readiness and Original/Translated/Bilingual display.
- Download the separate NLLB model, then translate Sinhala↔English with the **bundled native helper**, without a Python override. Confirm missing-model/helper errors are clear, cancellation is responsive and the next translation succeeds. Measure initial load, latency and memory; validate the same path from a packaged app before release.
- Live: start/stop/pause/resume, overlay line updates and translation; move/resize across displays, toggle click-through, verify restore per display and visible recording state. Check permission denial/recovery and device hot-plug. Ensure overlay does not activate or steal focus.
- Dictation: hold/toggle shortcuts into TextEdit, Notes and a browser field, with paste and AX insertion paths. Verify Accessibility denial links/retry, clipboard restoration, Escape cancellation, translated insertion timeout/fallback and no partial insertion on failure. Test the Home entry action and destination focus explicitly.

## Release gate

Follow `specs/qa/release.md` for local package verification, Developer ID signing/notarization and Sparkle configuration. Source tests, an ad-hoc DMG and script fixture checks do not prove notarization, Gatekeeper acceptance or successful update installation. Public feed/key provisioning and publication remain separate approved release actions.
