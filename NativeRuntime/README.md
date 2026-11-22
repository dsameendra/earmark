# Bundled native Sinhala translation runtime

The shipped runtime uses CTranslate2 **4.6.0** and SentencePiece **0.2.1**, built as static arm64 code for macOS 26+. `Packages/NLLBNative/Vendor/EarmarkNLLBCore.xcframework` contains the C bridge and both libraries; it links Apple's Accelerate framework and the Ruy CPU backend without an OpenMP or Python installation.

Pinned upstream revisions, archive SHA-256 and C-bridge SHA-256 are recorded in `Packages/NLLBNative/Vendor/provenance.json`. Third-party notices are in `Packages/NLLBNative/Vendor/LICENSES.txt` and are copied into the app. Model weights are user downloads and retain their separate licences; the archive contains no model weights.

## Runtime arrangement

`NativeRuntime/Bridge/earmark_nllb.cpp` exposes a C API for model loading, translation, exact SentencePiece tokenization and destruction. `Packages/NLLBNative/Sources/NLLBNative` wraps it for Swift. The `EarmarkNLLBWorker` executable runs a serial JSON-lines request loop with one loaded model and is embedded under `Earmark.app/Contents/Helpers/` by the app target.

The app's existing `NLLBRuntime` transport launches this native executable. Cancellation terminates the helper, releasing its inference work; a subsequent request can reload and restart it. This isolation retains the established beam-search configuration and permits cancellation without adding an interpreter dependency to a DMG. The explicit Python path remains a development reference override, not a shipped runtime requirement.

## Rebuild

With Xcode, a C++17 compiler, CMake >= 3.24 and Ninja available:

```sh
scripts/build-nllb-native.sh
swift build --package-path Packages/NLLBNative --product EarmarkNLLBWorker
```

The script fetches the pinned revisions into `EARMARK_NATIVE_BUILD_ROOT` (a temporary directory by default), compiles the libraries and bridge, and replaces the XCFramework only after a successful build. Review the resulting archive and update its provenance hashes after a deliberate rebuild; release preflight rejects a stale archive or bridge hash. The archived binary is rebuildable from these pins; byte-for-byte reproducibility across toolchain versions has not been established.

## Reference and integration checks

Use an already downloaded CT2 model directory containing `model.bin` and `sentencepiece.bpe.model`. The tests do not download weights.

```sh
export EARMARK_NLLB_MODEL_DIR="$PWD/.model-cache/nllb-ct2-int8"
swift test --package-path Packages/NLLBNative

export EARMARK_NATIVE_NLLB_HELPER="$PWD/Packages/NLLBNative/.build/debug/EarmarkNLLBWorker"
swift test --package-path Packages/Translation --filter NativeWorkerTests
```

The committed parity cases cover exact token pieces (including Unicode normalization and mixed Sinhala/English) and translations in both directions. The worker integration test covers translation, cancellation within one second, restart and a second successful translation. Without the model-directory/helper environment variables, the real-model suites are skipped; a passing skipped run is not a parity result.

`NativeRuntime/write-reference.py` regenerates the reference fixture using Python **3.12**, `ctranslate2==4.6.0` and `sentencepiece==0.2.1` in a development environment. Review fixture changes as model/runtime changes, rather than refreshing goldens merely to pass tests. The fixture records the exact model/tokenizer SHA-256 values used by that reference.

Upstream sources: [CTranslate2 4.6.0](https://github.com/OpenNMT/CTranslate2/tree/v4.6.0), [SentencePiece 0.2.1](https://github.com/google/sentencepiece/tree/v0.2.1), and [CTranslate2 build options](https://opennmt.net/CTranslate2/installation.html).
