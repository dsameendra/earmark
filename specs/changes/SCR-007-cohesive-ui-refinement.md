# SCR-007: Cohesive UI refinement after on-device review

Status: Authorized by the product owner in the current handover session, 2026-11-22.

The final-v1 boards in `specs/design/m8-mockups/` remain the visual reference. The owner's subsequent real-app review supersedes the old global 1120 pt workspace cap and Settings toolbar-tab layout. This refinement uses the available window width, a vertical Settings navigator, unified native window surfaces, consistent empty states, and adequate control spacing. Content remains solid; floating chrome retains the M8 glass budget.

Scope includes Home responsiveness; Live control separation; all fifteen Settings sections; titleless onboarding with artwork extending to the window edge and explicit reopening only through Settings and Help; a structured menu-bar panel; truthful dynamic model status; distinct Search, Find and Replace symbols; outside-click dismissal of Quick Open; playback keyboard ownership in docked and detached windows; and the M8 motion/reduced-motion pass.

Queue removal is a necessary AppCore contract extension: `JobQueue.remove(_:) async throws` removes queue history, cancels and joins active work when needed, and preserves transcripts and media. The default implementation reports unsupported removal. Production removal must persist before publishing success; errors leave a retryable row. Clear Finished retains failed work, and clearing active work requires an explicit in-app confirmation.

Brand correction restores the Main board's triangular 28% top-right curl and exact three-stop tile gradient in the native Icon Composer bundle. Language controls and onboarding treat Sinhala alongside the other supported languages. Catalog-backed choices preserve regional and multilingual selections; file imports use the same saved language/model defaults displayed by the app.

Acceptance evidence and remaining release gates are recorded in `specs/qa/ui-refinement-2026-11-22.md`. This refinement does not authorize deleting library content or changing capture permissions during QA.
