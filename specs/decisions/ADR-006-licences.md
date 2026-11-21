# ADR-006: Third-party model and library licences
Status: Accepted (2026-11-21)
Table: WhisperKit MIT; FluidAudio Apache-2.0 (+CC-BY-4.0 models); Qwen3-ASR-Sinhala CC BY-SA 4.0; MADLAD Apache-2.0; NLLB CC-BY-NC-4.0 (non-commercial only; model card says not for production); Sortformer unresolved (NVIDIA Open Model License vs CC-BY-4.0).
Decision: Models are user-downloaded, never bundled; Model Manager shows licence per model; commercial builds exclude NC models. Legal review before release.

## Sign-off update (2026-11-21)
Qwen3-ASR-Sinhala is CC BY-SA 4.0: weights are user-downloaded and unmodified, so share-alike does not extend to app code; attribution shown in Model Manager. Non-commercial posture accepted. Sortformer v2.1 (NVIDIA Open Model License) avoided.
