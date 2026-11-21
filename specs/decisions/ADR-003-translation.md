# ADR-003: Translation routing and licence gate
Status: Proposed
Decision: Apple Translation default (headless TranslationSession); Sinhala via MADLAD-3B (Apache-2.0) as on-demand download, NLLB-600M only in a non-commercial build; Whisper translate not used with turbo. English→Sinhala flagged low-confidence.
Open: MADLAD Swift runtime (llama.cpp support unconfirmed; may need CTranslate2/Rust FFI); TranslateGemma MLX as alternative after spot-check.
