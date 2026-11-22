# SCR-006: Update checks in the local-only network policy

Status: Approved scope, 2026-11-22. Records the owner's approval to complete Sparkle release preparation and the already accepted ADR-005 distribution decision.

The earlier absolute restriction to model downloads conflicts with the accepted update mechanism. Permit user-initiated update checks/downloads and automatic checks only after explicit opt-in. Default automatic checks remain off. No cloud transcription, cloud translation, telemetry, or analytics is introduced. Unconfigured and mock builds do not start the updater.

Update PROD-AC-01 and UI privacy copy accordingly. The release feed must use HTTPS and signed updates. No feed or private signing material is invented or committed.
