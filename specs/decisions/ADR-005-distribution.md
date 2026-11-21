# ADR-005: Distribution — non-sandboxed Developer ID, notarized, Sparkle 2
Status: Proposed (pending user confirmation)
Rationale: Process taps, global hotkeys, CGEvent insertion and Accessibility are impractical or impossible in the App Sandbox; Sparkle sandbox setup needs entitlements the Mac App Store rejects.
Evidence caveat: Apple docs were not fetchable; conclusion rests on SDK headers + Apple Developer Forum engineer statements. Consequence: Mac App Store excluded.
