# Screens review, 2026-11-23

Scope: FeatureShell, Home, Queue, Library, Live, Meetings, MenuBar, Onboarding, Settings, Support and the App views, everything
changed since 84365c5 plus the current code. No UI tests were run (they cannot run in the agent sandbox); every fix below is
covered by a unit test where the logic is testable without a UI.

## Fixed

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| 1 | High | `files.lastModel` (the Transcribe sheet's last pick) outranked `defaults.preferredModel.file`. After one sheet use, choosing a file model in the sidebar picker, Settings > Models or Languages changed the chip but never the model files actually used (ask-off adds, Home drops, re-transcribe). The sheet's own pick in turn never updated the chip. | `PreferredModel.set(_, for: .file)` mirrors into `files.lastModel`, and the sheet saves through `PreferredModel.set`, so every surface agrees. |
| 2 | Medium | Model picker: a download confirmed on one tab saved the model for whichever use case was selected when it finished (download on Files, switch to Live, the model became the Live model). | `PendingModelDownload` carries the use case; `confirmPending` persists to it. |
| 3 | Medium | Transcribe sheet: dismissing (Cancel, Esc) or switching model left the multi-hundred-MB download running silently; no way to cancel it; a model finishing after the selection moved on was not marked installed. | `cancelDownloads()` on Cancel, on disappear and when another model is picked; "Cancel Download" buttons; installed set refreshed when a stale download completes. |
| 4 | Medium | Sheet: a failed model or speaker-model download showed a raw `String(describing:)` error and the model one had no retry. A user-cancelled download surfaced as a red failure while the cancelled model stayed selected. | Friendly `ModelDownloadErrorText`, "Try Again" for both, a cancelled download returns to Automatic. |
| 5 | Medium | Sheet: "Transcribe" was silently disabled (everything already queued, no languages ticked, speaker model downloading). Submitting while the speaker model was downloading was allowed. | `submitBlockReason` shown under the form and as the button tooltip; blocks while the speaker model downloads. |
| 6 | Medium | Live: with no microphone connected but a saved device, the "Disconnected device" entry made `devices` non-empty so Start was enabled and then failed. | `startDisabledReason` reads the connected list. |
| 7 | Medium | Live had no inline permission recovery (Meetings, menu bar and Settings did). Denied mic or system audio produced only a failure screen. | `PermissionGateBanner` on the caption pane, filtered to the permissions the chosen source needs (`LiveSourceChoice.requiredPermissions`). |
| 8 | Low | `PermissionGateModel` treated an unread status as "not requested", so Meetings flashed a "needs access" banner for every granted user, and the Settings Audio/Dictation sections relied on that to load at all. | `hasLoaded`; nothing is blocked until the first read; the Settings panes load the gate themselves. Banner buttons wrap instead of clipping at large text. |
| 9 | Low | Queue: an add failure while the queue was empty was invisible (the empty state replaced the banner). Row icon buttons had no tooltips or identifiers. | Error banner above the empty state too; `.help` and `queue.pause/resume/cancel/retry.<id>` identifiers. |
| 10 | Low | Library: sort order was not persisted (layout was). Toolbar controls lacked tooltips and disabled-state reasons. | `library.sort` setting restored on launch; `.help` on every Library toolbar item including why Delete, Restore and Delete Permanently are disabled. |
| 11 | Low | Meetings toolbar put two policy menus in one glass capsule (every other screen uses one item per control). | One `ToolbarItem` per app. |
| 12 | Low | Settings > Models "Default" badge went stale when the file model changed in the picker or sheet. | `observe()` follows `defaults.preferredModel.file`. |
| 13 | Low | No keyboard shortcut or menu item for adding files. | File > Transcribe Files... (Cmd-O), mentioned in the toolbar tooltip. |
| 14 | Hardening | The persistent navigation pane relied on the removed toggle and Hide Sidebar command only; a divider drag could still collapse it. | `WorkspaceWindowChrome` sets `canCollapse = false` on the sidebar split item (main and Settings windows). Not verifiable without a UI run: please check by dragging the divider. |

## Verified, no change needed

- Sidebar cannot be collapsed by toolbar toggle (removed), menu (`CommandGroup(replacing: .sidebar) {}`) or binding (`.constant(.all)`).
  Window minimum is 960 x 600 (shell) and 900 x 620 (Settings); with a 232 pt sidebar the detail keeps at least 728 pt, enough for
  the Library, Live and Meetings toolbars.
- Every add path (Home drop, Queue drop, window drop, importer, menu bar "Transcribe File", Cmd-O) goes through
  `QueueModel.requestAdd`; ask-off enqueues with the saved choices and the shell navigates to the Queue.
- Model/language compatibility greying uses the single `ModelCompatibility` check in the sheet, the picker and Settings.
- Settings navigation: selection, up/down arrows, `.id(selection)` content reset with the header outside the scroll area.

## Open / not done

- `ModelPickerModel.select` ignores a `.paused` model (no resume from the picker); Settings > Models has Resume.
- Deleting a model that is the explicit Live or Dictation choice is not warned about (only the file default is).
- `LiveSessionSummary` is recomputed on every body evaluation: O(lines) per caption update. Fine for normal sessions; a multi-hour
  meeting would benefit from incremental counting in `LiveModel`.
- `diarize` on a batch with the speaker model missing is accepted (the sheet only explains and offers the download).
- Not checkable here (needs a UI run): Reduce Motion / Transparency / Increase Contrast visuals, Sinhala truncation, toolbar overflow
  at 960 pt, VoiceOver order. Code review found no hard-coded animation outside DSMotion in the touched views.
