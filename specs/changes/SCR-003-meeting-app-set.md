# SCR-003: MeetingApp covers only Zoom and Teams
Status: Proposed. Not applied.
Reason: `MeetingApp` is `zoom | teams` (matches the MTG spec scope). Google Meet runs in a browser, FaceTime and Slack huddles have no stable per-process audio signature, so the detector (`CoreAudioMeetingProbe`, per-process Core Audio activity by bundle ID) cannot see them (found by T23).
Current behaviour: the Meetings UI, the policy store and the recorder handle exactly these two cases; `MeetingAppSignature.defaults` is the one table mapping an app to bundle ID prefixes (`us.zoom.`, `com.microsoft.teams`).
Proposed change when more apps are wanted: additive cases on `MeetingApp` (for example `.webex` with prefix `Cisco-Systems.Spark`), a row in `MeetingAppSignature.defaults`, and a title in `FeatureSupport/MeetingSupport.swift`. Switches over `MeetingApp` (`MeetingApp.title`, `SystemMeetingSources.bundleID(for:)`, the folder name in `MeetingSessionController`) need the new case. Browser meetings need a different detection approach (window title or Accessibility) and are out of scope.
Impact: additive for AppCore; exhaustive switches in Features and App must be updated with the new case.
