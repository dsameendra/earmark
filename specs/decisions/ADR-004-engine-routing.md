# ADR-004: Engine routing and two-runtime ASR
Status: Proposed
Decision: Pure table-driven `EngineRouter`. SpeechAnalyzer for live/dictation on Apple-supported locales; WhisperKit large-v3-v20240930_626MB for files; Qwen3-ASR-Sinhala (MLX) default for Sinhala; Parakeet optional. Stock Whisper never used for Sinhala.
Consequences: MLX runtime (mlx-audio-swift pinned >= 01dec7c) added beside CoreML; tier-based model selection.
Open: Whisper-small-Sinhala CoreML fallback needs conversion (python 3.11 env) and uncontaminated eval.
