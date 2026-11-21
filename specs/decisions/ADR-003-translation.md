# ADR-003: Translation routing and licence gate
Status: Proposed
Decision: Apple Translation default (headless TranslationSession); Sinhala via MADLAD-3B (Apache-2.0) as on-demand download, NLLB-600M only in a non-commercial build; Whisper translate not used with turbo. English→Sinhala flagged low-confidence.
Open: MADLAD Swift runtime (llama.cpp support unconfirmed; may need CTranslate2/Rust FFI); TranslateGemma MLX as alternative after spot-check.

## Sign-off update (2026-11-21)
App is non-commercial: **NLLB-200 600M is primary for Sinhala<->English**, MADLAD-3B optional/alternative. NLLB card says "not for production deployment" and CC-BY-NC-4.0 binds any future monetisation (repo LICENSE is MIT for our code only; model weights stay under their own licences, user-downloaded). Attribution in Model Manager.
