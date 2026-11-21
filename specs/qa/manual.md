# Manual QA scripts (permission-gated / environment-gated)
Status: skeleton; filled in Phase 7. Items below are unverified until run.
- Mic capture, route change, unplug fallback (mic permission).
- Process tap on Zoom (us.zoom.xos): start/stop a test meeting; silent-denial detection when System Audio Recording is denied.
- **Teams (com.microsoft.teams2): not installed on the dev Mac; install the free client to verify detection and tap.**
- Accessibility: dictation insertion into TextEdit / Notes / browser field.
- TCC re-prompt behaviour across rebuilds with ad-hoc signing vs Personal Team.
- Crash safety: `kill -9` during recording leaves playable fragments.
