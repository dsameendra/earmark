# 13 — Onboarding (ONB)
Status: Draft. Owner: UI engineers.

## Scope
Short glass-styled flow: welcome → choose languages (English preselected, Sinhala offered) → download recommended model → permissions requested just in time → optional menu bar tour.

## AppCore protocols used
`ModelManaging`, `LanguageCapabilityTable`, `EngineRouter`, `HardwareTierProviding`, `PermissionsServicing`, `SettingsStore`.

## Acceptance criteria (EARS)
- ONB-AC-01 (UI) WHEN the app is launched for the first time THE SYSTEM SHALL show onboarding; WHEN completed or skipped THE SYSTEM SHALL not show it again (re-openable from Settings).
- ONB-AC-02 (UI) THE SYSTEM SHALL preselect English and offer additional languages, marking Sinhala as experimental.
- ONB-AC-03 (unit) WHEN languages are chosen THE SYSTEM SHALL compute the recommended model via `EngineRouter` for the hardware tier and display its size.
- ONB-AC-04 (UI/integration) WHEN the user accepts THE SYSTEM SHALL download the model showing progress with pause/cancel, and SHALL allow skipping (download later in Settings).
- ONB-AC-05 (UI) THE SYSTEM SHALL NOT request any permission during onboarding unless the user opts in; each permission SHALL be requested when its feature is first used, preceded by an explanation.
- ONB-AC-06 (UI) WHEN a permission is denied THE SYSTEM SHALL show recovery steps with a deep link.
- ONB-AC-07 (UI) THE SYSTEM SHALL offer an optional menu bar tour highlighting live captions, meeting capture and dictation.
- ONB-AC-08 (UI) THE SYSTEM SHALL show the one-time recording-consent notice before the first meeting capture.
- ONB-AC-09 (UI/manual) THE SYSTEM SHALL meet the accessibility criteria of NAV-AC-09…12 within onboarding.
- ONB-AC-10 (UI) WHEN offline THE SYSTEM SHALL explain that downloads need a connection and allow continuing without a model.

## Edge cases
Download interrupted: resume; insufficient disk: warn with size needed; Apple system assets (SpeechAnalyzer) download via system flow with progress.

## Non-functional
Flow completes in ≤ 5 screens; no network use until the user starts a download.
