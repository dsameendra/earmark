# ADR-005: Distribution — non-sandboxed Developer ID, notarized, Sparkle 2
Status: Accepted (2026-11-21)
Rationale: Process taps, global hotkeys, CGEvent insertion and Accessibility are impractical or impossible in the App Sandbox; Sparkle sandbox setup needs entitlements the Mac App Store rejects.
Evidence caveat: Apple docs were not fetchable; conclusion rests on SDK headers + Apple Developer Forum engineer statements. Consequence: Mac App Store excluded.

## Sign-off update (2026-11-21)
Sparkle 2 with automatic updates confirmed; Mac App Store excluded. Developer ID signing/notarization pending an Apple Developer Program account (none on this Mac); Sparkle EdDSA keys are generated at M7, private key never committed.
