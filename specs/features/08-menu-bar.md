# 08 — Menu Bar (MENU)
Status: Draft. Owner: UI engineers. Uses `MenuBarExtra(.window)`.

## Scope
Always-available menu bar item (even with the main window closed; Dock icon show/hide setting). State display, one-click actions, mini live preview, recording indicator.

## AppCore protocols used
`LiveSessionControlling`, `MeetingDetector`, `MeetingPolicy`, `JobQueue`, `AudioDeviceProviding`, `HotkeyServicing`, `PermissionsServicing`, `SettingsStore`.

## Acceptance criteria (EARS)
- MENU-AC-01 (UI) THE SYSTEM SHALL show a menu bar item at all times while the app runs, independent of main-window visibility.
- MENU-AC-02 (UI) WHEN state changes among idle, live captions on, meeting detected, meeting recording, dictation armed and queue running THE SYSTEM SHALL update the icon and a one-line status within 500 ms.
- MENU-AC-03 (UI) WHEN the user chooses Start Live Captions THE SYSTEM SHALL offer a source picker (Mic / System / Both) and start `LiveSessionControlling.start` with the chosen source.
- MENU-AC-04 (UI) WHEN a session is running THE SYSTEM SHALL show Stop and a preview of the last 2–3 caption lines.
- MENU-AC-05 (UI) WHEN the user chooses Start Meeting Capture THE SYSTEM SHALL start capture (and recording if "record" is chosen) for the detected or selected meeting app.
- MENU-AC-06 (UI) THE SYSTEM SHALL provide: Toggle auto-record, Transcribe File…, open Queue, open Library, quick mic picker, quick language picker, Settings, Quit.
- MENU-AC-07 (UI) WHILE recording is active THE SYSTEM SHALL show a persistent recording indicator in the menu bar (PROD-AC-07) and the icon SHALL animate subtly unless Reduce Motion is on.
- MENU-AC-08 (UI) WHEN "Show Dock icon" is off THE SYSTEM SHALL run as an accessory app and SHALL still be able to open the main window from the menu.
- MENU-AC-09 (UI) WHEN a language is selected in the quick picker THE SYSTEM SHALL apply it as the default `LanguageMode` for the next session.
- MENU-AC-10 (UI) WHEN the selected mic disappears THE SYSTEM SHALL fall back to the system default and post a notification (see AUD).
- MENU-AC-11 (integration) WHEN idle with only the menu bar running THE SYSTEM SHALL use < 1 % CPU and < 150 MB RAM with no model loaded.
- MENU-AC-12 (manual) THE SYSTEM SHALL expose all menu items to VoiceOver and keyboard navigation.
- MENU-AC-13 (UI) WHEN Reduce Transparency is on THE SYSTEM SHALL render the popover with a solid background.

## Edge cases
Permission missing: action shows a "Grant permission" row linking to settings (via `PermissionsServicing.settingsURL`). Model not installed: inline progress (NAV-AC-07). No input device: disabled Start with reason.

## Non-functional
Popover opens < 150 ms; no timers while hidden (event-driven updates).
