## What and why

<!-- A sentence or two. Link the issue if there is one. -->

## Checks
- [ ] `scripts/check.sh unit` (or the affected packages with `swift test --no-parallel`) passes
- [ ] UI or layout change: I looked at a screenshot of the real window (light and dark)
- [ ] No cloud calls, telemetry or new network use outside model downloads and update checks
- [ ] Contract changes have a change request in `specs/changes/`
- [ ] No keys, certificates or personal data in the diff
