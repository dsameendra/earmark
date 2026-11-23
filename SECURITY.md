# Security policy

Earmark processes audio and transcripts entirely on your Mac. It has no accounts and no telemetry; the only network use is model downloads you start and update checks you opt into (HTTPS, EdDSA-signed updates).

## Supported versions
Only the latest release receives security fixes.

## Reporting a vulnerability
Please **do not open a public issue**. Report it privately through GitHub:
**Security tab → Report a vulnerability** on https://github.com/dsameendra/earmark

Include what you found, how to reproduce it, and the Earmark and macOS versions. You can expect an acknowledgement within a few days. Fixes ship as a normal update; credit is given if you want it.

## Scope notes
- Releases are signed with a self-signed certificate and are not notarized (see the README for the first-launch approval). Reports about that choice are not vulnerabilities.
- Signing keys are never stored in the repository or in CI secrets.
