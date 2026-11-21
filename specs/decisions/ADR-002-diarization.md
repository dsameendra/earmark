# ADR-002: Diarization — FluidAudio primary, SpeakerKit fallback
Status: Proposed. Live engine: LS-EEND `.ami` primary (DER 15.7 pooled, best case; 4 speakers max), Sortformer v2 (CC-BY) fallback; avoid Sortformer v2.1 (NVIDIA Open Model License: revocable, indemnity). Live labels provisional, reconciled by offline pass via max-overlap mapping.
Evidence: specs/research/diarization.md — DER tied on 3 AMI meetings (strict 18.1 vs 19.2; lenient 7.5 vs 6.2); FluidAudio exact speaker count 3/3, cleaner embeddings, has streaming; SpeakerKit offline only.
Decision: `Diarizer` protocol; FluidAudio Community-1 offline + a streaming FluidAudio engine for live labels; SpeakerKit adapter as swappable fallback.
Risks: Sortformer licence unresolved; CC-BY-4.0 attribution; voice-match threshold needs calibration.
