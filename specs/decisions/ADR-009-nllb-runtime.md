# ADR-009: Bundled native NLLB runtime for Sinhala translation

Status: Accepted and implemented (2026-11-22), under the owner-approved completion integration in [SCR-005](../changes/SCR-005-completion-integration.md). Distribution and hardware QA remain release gates.

## Context

ADR-003 selects NLLB-200 distilled 600M as the non-commercial Sinhala translation engine. Its user-downloaded weights are an int8 CTranslate2 conversion and retain CC-BY-NC-4.0. Inference requires CTranslate2 and SentencePiece. The original development runtime was a persistent Python worker over JSON lines; requiring the user's interpreter and packages is unsuitable for a self-contained app.

## Decision and implementation

Bundle an **arm64 macOS 26+** native worker, `EarmarkNLLBWorker`, under `Earmark.app/Contents/Helpers/`. Its Swift executable links the C bridge, **CTranslate2 4.6.0** and **SentencePiece 0.2.1** from the static `EarmarkNLLBCore.xcframework`. The CPU backend uses Accelerate/Ruy, without OpenMP or Python. The app target embeds the worker; release tooling signs nested code before the containing app.

`BundledNLLBRuntime` locates the executable and supplies the existing `NLLBRuntime` transport. The worker accepts serial JSON-lines requests, tokenizes with the real SentencePiece library, loads one model and retains it for subsequent requests. Cancellation terminates the helper to interrupt inference and release its memory; a later request starts a new worker. The app's translation router remains Apple-first where supported, with native NLLB for Sinhala and eligible fallback pairs.

The runtime code is bundled; **model weights are not**. Existing model-download, licence, progress and readiness flows still apply. If the helper is missing or not executable, the runtime is unavailable and Sinhala readiness reports that state rather than silently depending on Python.

Debug builds may explicitly select the reference Python runtime with `EARMARK_DEV_NLLB_PYTHON=/absolute/path/to/python3` or the existing development setting. The interpreter must have compatible `ctranslate2` and `sentencepiece` packages. Release ignores that override and selects only the bundled native worker.

## Provenance and verification

Pinned upstream revisions, architecture/backend choices, archive SHA-256 and C-bridge SHA-256 are recorded in `Packages/NLLBNative/Vendor/provenance.json`. Runtime notices are copied into app resources. `scripts/build-nllb-native.sh` rebuilds the archive from the pinned revisions; a deliberate rebuild requires reviewing/updating provenance. Byte-for-byte reproducibility across Xcode versions has not been established.

The native tests contain exact token-piece and translation reference cases for Sinhala/English, normalization and code mixing. Worker integration tests cover translation, cancellation and restart. These real-model tests run only when their model/helper environment variables are supplied; skipped tests do not prove parity. See [NativeRuntime/README.md](../../NativeRuntime/README.md) for commands and fixture provenance. A final full serial regression recheck was still running at this documentation update; its results must be recorded separately.

## Consequences and remaining gates

- The packaged app has no user-installed interpreter requirement; a missing helper is an explicit packaging/readiness failure.
- Helper process isolation supports prompt cancellation, at the cost of reloading the model after cancellation and a separate executable to sign.
- The current binary supports Apple silicon only, macOS 26+. Intel support requires a separate build and validation decision.
- CC-BY-NC-4.0 weights remain restricted to non-commercial use. Bundling inference code does not authorize commercial use or remove model attribution obligations (ADR-003, ADR-006).
- Actual packaged-app translation, memory/latency on target hardware, Developer ID signatures, notarization and Gatekeeper acceptance remain release checks. A passing source/package test is not a signed-distribution result.
