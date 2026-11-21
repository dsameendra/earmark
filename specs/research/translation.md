# Translation spike (Phase 0)

Access date for all web sources: 2026-11-21. Machine: M3 Pro 18 GB, macOS 27.2.1, SDK MacOSX27.2.sdk, Swift 6.4.
Legend: [V] verified on this machine or from a primary source fetched today; [E] estimate / not verified; [U] UNVERIFIED pending user run.
No timed benchmarks were run. No model weights were downloaded (only tokenizer JSONs for token checks, in `.model-cache/probe-tok/`).

## 1. Apple Translation framework

### 1.1 API surface on the installed SDK [V]
Source: `Translation.framework/Modules/Translation.swiftmodule/arm64e-apple-macos.swiftinterface` in MacOSX27.2.sdk. Apple's developer docs pages are JS-rendered and returned no body to the fetch tool, so the SDK interface is the primary source.

- `LanguageAvailability`: `supportedLanguages` (async), `status(from:to:)`, `status(for:to:)` (async, detects language), `preferredStrategy` (26.4+).
- `TranslationSession`: `translate(_:)`, `translate(batch:)` (AsyncSequence of responses), `translations(from:)` (async, returns `[Response]`), `prepareTranslation()`, `cancel()`, `isReady`, `canRequestDownloads` (26.0+).
- `Request(sourceText:clientIdentifier:)`, `Response` carries `clientIdentifier` to match output to input.
- Strategies (macOS 26.4+): `.highFidelity`, `.lowLatency`.
- AttributedString translation with `skipsTranslation` attribute (26.4+).
- **Headless session (macOS 26.0+):** `TranslationSession(installedSource:target:)` (and a 26.4 overload with `preferredStrategy`). This removes the SwiftUI `translationTask` view requirement for pairs that are already installed.
- Errors: `unsupportedLanguagePairing`, `unsupportedSourceLanguage/TargetLanguage`, `notInstalled` (26.0+), `unableToIdentifyLanguage`, `nothingToTranslate`, `alreadyCancelled`, `internalError`.

### 1.2 Supported languages on this machine [V]
Probe: `spikes/translation/LanguageProbe.swift`, output in `spikes/translation/supported-languages-output.txt`.
`supportedLanguages` returned 47 identifiers: ar-AE ar-SA da de de-AT de-CH en (+ en-AU/CA/GB/IE/IN/NZ/SG/ZA) es es-CL es-MX es-US fi fr fr-BE fr-CA fr-CH he hi id it it-CH ja ko ms nb nl nl-BE pl pt pt-PT ru sv th tr uk vi zh zh-HK zh-TW.
- **Sinhala (`si`) is NOT supported.** `contains si: false`; `status(from: si, to: en)` and `status(from: en, to: si)` both return `unsupported`. Confirmed.
- Every listed language reported `installed` for ->en on this machine (including the pairs we did not download ourselves). Caveat: this is state of this particular macOS 27.2.1 install; on a user's clean macOS 26 machine many pairs will be `supported` (downloadable), not `installed`. Do not assume preinstalled models. [E]
- Always query at runtime instead of hard-coding the list.
- Regional English variants as source report `unsupported` when targeting `en`; normalise to `en` / script-level tags before querying.
- Non-English pairs work directly: ja->ko, de->fr, hi->en, en->ja all `installed`, and a headless de->fr session returned "Bonjour" for "Guten Morgen" [V]. No English pivot needed for Apple pairs.

### 1.3 Headless use, download flow, batching
Probe: `spikes/translation/SessionProbe.swift`. Ran as an unsandboxed CLI: `status es->en: installed`, `isReady: true`, `canRequestDownloads: false`; a 3-request batch via `translations(from:)` returned correct English ("Good morning everyone." / "The meeting starts in five minutes." / "Can we review the budget?"). [V] (quality spot-check only, not timed).

Recommended flow for the app:
1. At language selection, call `LanguageAvailability().status(from:to:)`.
2. `installed`: create `TranslationSession(installedSource:target:)` anywhere (actor, background task); no UI needed.
3. `supported` (not installed): downloads probably need system UI. `canRequestDownloads` was `false` for the headless session, but this test was confounded (pair already installed; no non-installed pair was available to test) [E]. Use a SwiftUI `.translationTask(configuration)` (or `.translationPresentation`) in a small onboarding/settings view and call `session.prepareTranslation()` there to show the system download sheet. After it completes, headless sessions work. [E: download sheet from `translationTask` not exercised here; needs a UI run, [U]]
4. `unsupported` (e.g. Sinhala): route to the local model path (section 2).
5. Batching: pass the whole transcript segment list as `[Request]` with `clientIdentifier = segment id`; use `translations(from:)` for the final pass or `translate(batch:)` to stream results into the UI. Sessions are meant to be reused for many requests. Keep batches by paragraph/speaker turn rather than single words for context. [E]
6. Offline: after install, translation runs on-device with no network. We did not test with network disabled. [U]

UNVERIFIED pending user run: (a) the download sheet from `translationTask` on a clean machine; (b) behavior with Wi-Fi off; (c) hosting `translationTask` in a hidden/zero-size view (commonly done, but sheet presentation may need a visible window).

## 2. Sinhala <-> English local options

All sizes from Hugging Face API/file listings fetched today unless marked [E].

| Model | Params | Licence | Size on disk | Sinhala support check | Format / runtime feasibility on Apple Silicon |
|---|---|---|---|---|---|
| NLLB-200 distilled 600M (`facebook/nllb-200-distilled-600M`, commit f8d333a0, 2024-02-14) | 600M | **CC-BY-NC-4.0** weights; MIT code (fairseq) | 2.46 GB fp32 `pytorch_model.bin`; ~0.6-0.8 GB int8 CT2 [E] | `sin_Sinh` and `eng_Latn` tokens present in tokenizer.json [V] | CT2 int8 conversions exist on HF (CPU only; no Metal/ANE backend). No MLX or CoreML conversion found on HF search [V]. PyTorch MPS works. Core ML needs custom conversion [E, U]. |
| NLLB-200 distilled 1.3B | 1.3B | CC-BY-NC-4.0 | ~5.5 GB fp32 [E]; CT2 int8 on HF (OpenNMT) | same family | same as above; better quality than 600M |
| MADLAD-400 3B MT (`google/madlad400-3b-mt`, sha fa184c67, 2023-11-27) | 3B (T5 enc-dec) | **Apache-2.0** | 11.76 GB fp32 safetensors; GGUF q4k 1.65 GB, q3k 1.26 GB, q2k 0.97 GB [V] | `<2si>` token present in tokenizer.json [V] | GGUF on HF (jbochi, google). llama.cpp T5 encoder-decoder support is needed [U]. No MLX/CoreML on HF [V]. mlx-examples t5 supports T5/FLAN-T5 only, not MADLAD [V]. |
| MADLAD-400 7B / 10B | 7.2B/10.7B | Apache-2.0 | 7B GGUF available [V]; too big for comfortable 18 GB use alongside Whisper | same | not recommended on 18 GB with ASR resident |
| M2M-100 418M (`facebook/m2m100_418M`) | 418M | **MIT** [V] | ~1.9 GB fp32 [E] | `si` listed [V] | CT2/HF; quality markedly below NLLB for low-resource [E]; weak fallback, permissive |
| TranslateGemma 4B/12B/27B (`google/translategemma-*-it`, report arXiv 2601.09012, Jan 2026) | 4B/12B/27B | **Gemma terms** (custom; gated) | MLX 4-bit/8-bit exist under mlx-community (4B/12B/27B) [V] | Benchmarked set is WMT24++ 55 languages; a Google rep says the chat template lists 160 base languages. **Sinhala IS in the chat template** (`"si": "Sinhala"` in `chat_template.jinja` of the ungated mlx-community/translategemma-4b-it-4bit) [V]; it is not in the benchmarked 55, so quality is unmeasured [U]. | **MLX available**, runs via mlx-swift-lm / mlx-lm. Best-fit "LLM via MLX" path if Sinhala is in the template. 4B WMT24++ MetricX 5.32 / COMET 81.6; 12B 3.60/83.5 [V]. |
| Gemma 3 instruct 4B/12B (mlx-community 4-bit) | 4B/12B | Gemma terms | 4B 4-bit ~2.5-3 GB, 12B 4-bit ~7 GB [E] | Gemma 3 claims broad multilingual coverage; Sinhala quality unverified [U] | MLX ready |
| Qwen3 8B instruct | 8.2B | **Apache-2.0** [V] | ~4.5-5 GB at 4-bit [E] | Card says "100+ languages", Sinhala not named [V]; expect weak Sinhala [E] | MLX ready |
| Opus-MT (Helsinki) | ~75M | Apache/CC-BY | small | HF search for `opus-mt-si` found no Sinhala-English model; only an unlicensed mt5 en-si finetune [V] | not an option |

Quality evidence (primary, limited): NLLB paper (arXiv 2207.04672) reports FLORES-200 chrF++; a Claude-vs-NLLB paper (arXiv 2404.13813) lists Sinhala chrF++ for NLLB-54B at 60.54 (xxx->eng) and 42.65 (eng->xxx), Google Translate 63.62 / 49.92. The 600M distilled model is lower than 54B [E]. The pattern is clear: Sinhala->English is usable, English->Sinhala is substantially worse. No clean FLORES sin_Sinh numbers for MADLAD-3B, TranslateGemma or Qwen were found; do not assume they beat NLLB-600M. A quality spot check on a Sinhala test set is required before choosing [U, scripts provided].

### NLLB licence implications (CC-BY-NC-4.0) - FLAG
- Model card: "NLLB-200 is a research model and is not released for production deployment"; primary use is MT research; 512-token limit; not for document-level translation (verified from the HF README).
- CC-BY-NC forbids commercial use. Any paid app, paid tier, or distribution by a company in a commercial context is at best a grey area. Redistributing (bundling) the weights inside an app also triggers the attribution and NC terms. Free, open-source, personal-use distribution with attribution and an in-app "downloaded by the user from HF" flow is the lowest-risk use but still carries the NC clause.
- Safe pattern if the app stays non-commercial: do not bundle the weights; let the user download from Hugging Face (user accepts licence); show attribution.

## 3. Whisper translate task

Primary: openai/whisper discussion #2363 (maintainer statements).
- The translate task (any language -> English) exists only in the multilingual models. **turbo was fine-tuned on transcription data excluding translation data and is not expected to translate well**; users report it returning the source language. Use large-v3 (or large-v2) for the translate task, which costs the speed benefit of turbo.
- Turbo degrades more on some languages (Thai, Cantonese per maintainer). Hallucination/dropped segments on long/silent audio are reported.
- Whisper output is English only; no English -> other direction, and no Sinhala output.
- Whisper does list Sinhala as a source language, but low-resource accuracy is weak [E, not measured here].
- Compared with "transcribe then translate": Whisper translate loses the source transcript, gives no timestamps alignment to source text, and mixes errors. For the app, prefer transcribe (turbo) then translate text (Apple or local model); offer Whisper translate-to-English only as an optional "quick English" mode using a large model. [E]
- Script/steps: `spikes/translation/scripts/whisper_translate_probe.md` [U].

## 4. TRANSLATION ROUTING TABLE

Source language detection comes from the ASR result; user picks target (default English).

| # | Source | Target | Primary engine | Fallback | Notes |
|---|---|---|---|---|---|
| 1 | Any language in Apple's 47-language list (status `installed`) | any other Apple-supported (incl. English) | Apple Translation, headless `TranslationSession(installedSource:target:)` | Local LLM (TranslateGemma/MLX) if user opts in | offline, no licence issues, sandbox-safe |
| 2 | Apple-supported (status `supported`, not installed) | Apple-supported | Apple Translation after one-time download via `translationTask` + `prepareTranslation()` | If user declines: local LLM | needs UI at first use |
| 3 | Sinhala (si) | English | Commercial: MADLAD-400 3B (Apache-2.0, GGUF q4). Non-commercial: NLLB-200 600M/1.3B (CT2 int8) | TranslateGemma 4B/12B MLX if Sinhala is verified [U] | Apple unsupported (confirmed) |
| 4 | English | Sinhala | Same as row 3 (quality is notably lower than si->en; label output "machine translated, low confidence") | TranslateGemma 12B MLX [U] | |
| 5 | Sinhala | non-English target | Pivot: si->en (row 3) then en->target (row 1) | | two-hop errors compound; show English intermediate |
| 6 | Non-English target -> Sinhala | | Pivot: src->en (row 1) then en->si (row 4) | | |
| 7 | Language unsupported by Apple and not Sinhala (e.g. Tamil, Bengali, Urdu) | English | MADLAD-400 3B (commercial) / NLLB (non-commercial) | LLM | both cover hundreds of languages [E for each specific language] |
| 8 | Any | English, but user wants "no separate translation model" | Whisper translate task with large-v3 (not turbo) | row 1/3 | optional mode only |
| 9 | Language identified with low confidence | any | Ask user to confirm the source language before translating | | `unableToIdentifyLanguage` error path |

## 5. Model size / quality / licence trade-off

| Option | Disk | RAM at runtime [E] | si->en quality | en->si quality | Licence | Commercial OK |
|---|---|---|---|---|---|---|
| Apple Translation | system-managed (~100s MB per language, [E]) | system | n/a (unsupported) | n/a | system API | Yes |
| NLLB-200 distilled 600M (int8) | ~0.7 GB | ~1.5 GB | acceptable (lowest of the dedicated MT set) | weak-moderate | CC-BY-NC-4.0 | **No** |
| NLLB-200 distilled 1.3B (int8) | ~1.5 GB | ~3 GB | better than 600M | moderate | CC-BY-NC-4.0 | **No** |
| MADLAD-400 3B (GGUF q4k) | 1.65 GB | ~3 GB | unmeasured (no Sinhala figure sourced) | unmeasured | Apache-2.0 | Yes |
| M2M-100 418M | ~1 GB | ~2 GB | poor | poor | MIT | Yes |
| TranslateGemma 4B 4-bit | ~2.5-3 GB | ~4 GB | unverified | unverified | Gemma terms (gated) | Permitted with conditions, see note below [V] |
| TranslateGemma 12B 4-bit | ~7 GB | ~9 GB | unverified, likely best of LLM options | unverified | Gemma terms | Yes with terms |
| Qwen3 8B 4-bit | ~4.5-5 GB | ~6 GB | likely weak for Sinhala | likely poor | Apache-2.0 | Yes |
| Whisper large-v3 translate | ~3 GB (CoreML) | ~3-4 GB | n/a (English only target; Sinhala ASR weak) | n/a | MIT [V, openai/whisper LICENSE] | Yes |

18 GB constraint: ASR (Whisper) + diarization + translation model resident concurrently; prefer loading the MT model on demand and unloading after the batch. MADLAD 3B or NLLB are the only options that coexist comfortably; 12B LLM should be sequential. [E]

Gemma terms (read at https://gemma.ai/resources/terms/, reached by a 301 from ai.google.dev/gemma/terms; page copyright Google DeepMind, "Google" = Google LLC; last modified April 1, 2026) [V]: no explicit ban on commercial use; rights to use, reproduce, modify, distribute. Redistribution (Sec 3.1) requires: flow-down of the Sec 3.2 use restrictions to downstream agreements and notice to recipients; a copy of the Agreement to recipients; prominent notices on modified files; a "Notice" text file for non-hosted distribution. Prohibited Use Policy is incorporated by reference. Google claims no rights in outputs (3.3). Not Apache-style: a user-downloaded (not bundled) flow minimises obligations. The page notes Gemma 4 is under a separate licence; the mlx-community Gemma 3 / TranslateGemma repos carry the `gemma` tag.

## 6. Runtime feasibility notes (CoreML / MLX Swift / other)
- No NLLB or MADLAD checkpoint exists in MLX or Core ML format on HF (search today). mlx-examples/t5 covers T5/FLAN-T5 only. Porting M2M100/NLLB (enc-dec with sinusoidal positions, 256k vocab) or MADLAD (T5 with relative bias) to MLX Swift is a custom engineering task, not a drop-in. [E]
- Practical in-app options: (a) **Candle (Rust) is the only documented runtime for the jbochi MADLAD GGUFs** (`cargo run --example quantized-t5`, per the model card [V]); the card does not say llama.cpp can load them. I could not verify llama.cpp T5 support (docs fetch inconclusive), and GGUFs made for candle may use different tensor naming, so treat llama.cpp loading as unproven [U]. For Swift this means Rust FFI (candle) or converting MADLAD yourself (HF -> llama.cpp GGUF, or CT2 `ct2-transformers-converter`; a community CT2 int8_float16 conversion of the 7B-bt model exists [V]); (b) CTranslate2 (C++, CPU, int8) for NLLB or MADLAD; adds a C++ dependency, no GPU; for a 600M model CPU speed is likely acceptable but deferred [U]; (c) MLX LLM via mlx-swift-lm for TranslateGemma/Gemma/Qwen; the cleanest Swift integration. [E]
- Scripts for the quality/speed spot checks (all [U], none run): `spikes/translation/scripts/{nllb_ct2_probe.py,madlad_gguf_probe.sh,mlx_llm_probe.py}`. Each prints translations for three Sinhala/English test sentences; `nllb_ct2_probe.py` has a `bench` flag for timing, to be used on an idle machine.

## Sources
- MacOSX27.2.sdk Translation.swiftinterface (local), accessed 2026-11-21.
- https://huggingface.co/facebook/nllb-200-distilled-600M (+ /api/models, commit f8d333a0), https://github.com/facebookresearch/fairseq/tree/nllb
- https://huggingface.co/google/madlad400-3b-mt (commit fa184c67), https://huggingface.co/facebook/m2m100_418M
- https://huggingface.co/google/translategemma-4b-it, https://arxiv.org/abs/2601.09012, https://huggingface.co/google/translategemma-27b-it/discussions/1
- https://huggingface.co/Qwen/Qwen3-8B, HF model search APIs (nllb, madlad400, translategemma, mlx-community gemma-3, opus-mt-si)
- https://github.com/openai/whisper/discussions/2363
- https://github.com/ml-explore/mlx-examples/tree/main/t5
- https://arxiv.org/pdf/2404.13813, https://arxiv.org/pdf/2207.04672

## Recommendation
1. Use Apple Translation (headless session for installed pairs, `translationTask`+`prepareTranslation()` once for downloads) as the default engine for all supported pairs. Sinhala is confirmed unsupported.
2. For Sinhala, ship an optional, on-demand "Sinhala translation pack" instead of bundling: commercial build uses **MADLAD-400 3B (Apache-2.0, GGUF q4 1.65 GB)**, pending a spot-check that its si->en quality is acceptable (compare against NLLB-600M and TranslateGemma on a 30-50 sentence Sinhala set). Non-commercial/personal build may offer NLLB-200 (600M or 1.3B), user-downloaded, with attribution and licence notice.
3. Treat en->si as low-confidence and label it so. Pivot through English for other pairs.
4. TranslateGemma (MLX, Gemma terms) lists Sinhala in its template but has no published Sinhala quality; include it in the spot-check and offer it only if it passes. Runtime note: MADLAD's easiest verified runtime is candle (Rust), so the commercial path may need Rust FFI or a self-converted CT2 model; if that cost is too high, TranslateGemma via MLX is the cheapest Swift-native commercial path (Gemma terms).
5. Do not use Whisper turbo for translate; if "translate to English" is wanted from audio, use transcribe then text translation.
6. Decision gate for the user: is Earmark commercial (paid, closed or App Store)? If yes, drop NLLB entirely.

## Routing-table rows
See section 4, rows 1-9. Machine-readable summary:
- `apple_supported(src) && apple_supported(dst)` -> Apple Translation (download if `supported`).
- `src == si || dst == si` -> si<->en via MADLAD-3B (commercial) or NLLB (non-commercial); pivot via English for non-English counterpart.
- `unsupported by Apple, not si` -> ->English via MADLAD/NLLB.
- `audio -> English only, user opts in` -> Whisper large-v3 translate (never turbo).

## Sandbox/distribution flags
- Apple Translation: no special entitlement is documented in what we read; the CLI test ran unsandboxed. Sandboxed behavior of headless sessions and the download sheet is [U].
- Downloading models at runtime from Hugging Face needs `com.apple.security.network.client` if sandboxed (Mac App Store builds are fine with this). Bundling models inflates the app (MADLAD q4 1.65 GB); better as on-demand download into Application Support. Mac App Store review rules on downloading executable code do not apply to weights, but llama.cpp/CT2 are native libs that must be embedded and signed. [E]
- NLLB CC-BY-NC weights: cannot be bundled or sold in a commercial build; also do not bundle in a free build without attribution and NC notice. See section 2.
- Gemma-based weights: Gemma terms require carrying use restrictions downstream; gated on HF (login/accept). Re-read terms before distribution.
- MADLAD GGUFs are documented only for candle (Rust); embedding needs a Rust static lib signed with the app. MADLAD is Apache-2.0, but trained on CommonCrawl-derived data; the model card warns of toxic/low-quality output.
- Non-sandboxed distribution (Developer ID + notarization) makes llama.cpp/CT2/Python-based runners easier; a sandboxed MAS build is feasible but needs the runtime embedded in-process. Not tested.

## Open questions for the user
1. Is Earmark going to be commercial (paid, subscription, or in a company context)? This decides NLLB vs MADLAD.
2. How important is English -> Sinhala (vs Sinhala -> English)? Quality gap is large; is "low-confidence" labeling acceptable?
3. Do you have a Sinhala (audio or text) test set, or can you provide 30-50 sentences with reference English, to choose between MADLAD, NLLB and TranslateGemma?
4. App Store (sandboxed) or direct distribution? Affects which runtime (llama.cpp / CT2 / MLX) is practical.
5. Are other non-Apple languages required (Tamil, Bengali, Urdu)? MADLAD/NLLB cover them but the routing table needs a decision on pack size.
6. Can you run the UI-dependent checks: `translationTask` download sheet on a clean machine, Wi-Fi-off translation, hidden-view hosting? (marked [U])

