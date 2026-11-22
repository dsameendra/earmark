# ADR-009: NLLB runtime for Sinhala translation (DRAFT)
Status: Draft (2026-11-22). Needs a decision before any release build; not blocking development.

## Context
ADR-003 makes NLLB-200 distilled 600M (CC-BY-NC-4.0, user-downloaded) the Sinhala translation engine. The model is an int8 CTranslate2 conversion; running it needs CTranslate2 (C++) and SentencePiece (C++). Neither has a Swift package, and there is no MLX or Core ML conversion of NLLB (`specs/research/translation.md` section 6).

`EarmarkTranslation.NLLBEngine` therefore runs through the `NLLBRuntime` protocol, and the only implementation today is `CTranslate2WorkerRuntime`: a persistent Python worker (JSON lines over stdio) that needs a user-installed interpreter with `ctranslate2` and `sentencepiece`. It is verified on this Mac and is acceptable for development and measurement. It is **not shippable**: an app must not depend on the user's Python, and a sandboxed build cannot launch it.

## Current behaviour (this build)
- The worker is **off by default**. It is enabled only by `EARMARK_DEV_NLLB_PYTHON=/path/to/python3` (see `NLLBDevRuntime`).
- Without the flag the router has no NLLB engine. Any pair involving Sinhala fails with `TranslationFailure.noEngine`, shown as "Sinhala translation unavailable in this build". The Translate popover lists Sinhala as unavailable with that reason; Apple-translatable pairs are unaffected.
- With the flag, the NLLB model is still a normal user download through `ModelManaging.ensureAvailable` (size and licence shown first), and the translate job, live translation and dictation use it through the router.

## Gap to a shippable runtime
1. **libctranslate2 C shim**: build CTranslate2 (CPU, Accelerate/Ruy backend; no CUDA) as a static library behind a small C API (`load(folder)`, `translate(tokens, source, target, beam)`, `unload`), packaged as an `.xcframework` and a Swift target. Estimate: a few days; the risk is the build of CTranslate2's dependencies for arm64 macOS and the binary size (about 10 MB of code).
2. **Swift SentencePiece**: the NLLB tokenizer is a SentencePiece model plus FLORES language tags. Either wrap the C++ library in the same shim or port the unigram encode/decode (small, but the normalisation rules must match exactly). Tokenizer mismatches produce quietly wrong output, so golden tests against the Python reference are required.
3. **Licence**: CC-BY-NC-4.0 weights; a commercial build cannot ship or recommend NLLB (see ADR-003, ADR-006). The shippable runtime is only needed for the non-commercial distribution.
4. **Alternatives** if the shim is rejected: MADLAD-3B (Apache-2.0) via a runtime with Swift support, or TranslateGemma on MLX after a Sinhala quality spot-check (ADR-003 open items).

## Decision needed
Choose between building the shim (1 and 2) or switching Sinhala translation to an MLX-based model. Until then the Python worker stays behind the dev flag and the UI reports the unavailable state clearly.
