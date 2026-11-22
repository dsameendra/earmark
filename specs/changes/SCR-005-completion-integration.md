# SCR-005: Approved completion integration

Status: Approved by the product owner on 2026-11-22 with the Codex handover plan.

Scope: recover T34; complete M8 in DesignSystem and feature views; connect Home meeting/dictation entry points to existing services; replace the Audio settings meter placeholder; recover visibly from persistent database failures; add the bundled CTranslate2/SentencePiece translation runtime behind the existing `NLLBRuntime` protocol; complete release tooling and QA.

Keep AppCore protocols and persisted data compatible. Any additional schema or public contract change must be documented separately. DesignSystem additions remain in the existing package. Preserve all fifteen Settings sections and existing editor, queue, capture, and export behaviours. No public distribution is complete until Developer ID signing, notarization, and real permission-gated QA pass.
