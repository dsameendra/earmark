# ASR engines spike (Phase 0)

Accessed 2026-11-21. Machine: M3 Pro 18 GB, macOS 27.2.1, Xcode 27.2 (SDK MacOSX27.2), Swift 6.4.2. Product targets macOS 26+.
Evidence tags: [RAN] executed here; [SDK] read from the installed Speech.framework swiftinterface (`.../MacOSX.sdk/System/Library/Frameworks/Speech.framework/.../arm64e-apple-macos.swiftinterface`); [WEB] URL + date; [UNVERIFIED] not run.
No timings were taken (shared CPU/GPU/ANE). Apple's docs pages are JS-rendered and WebFetch returned no body, so Apple API facts come from the SDK interface, which is stronger evidence.

## 1. Apple SpeechAnalyzer / SpeechTranscriber / DictationTranscriber

### Locales (the key finding)
[RAN] `spikes/asr` `asr-poc locales` on this machine (macOS 27.2.1):
- SpeechTranscriber.supportedLocales (45): bn_IN, de_AT/CH/DE, en_AU/CA/GB/IE/IN/NZ/SG/US/ZA, es_CL/ES/MX/US, fr_BE/CA/CH/FR, gu_IN, hi_IN, it_CH/IT, ja_JP, kn_IN, ko_KR, ks_IN, mai_IN, ml_IN, mr_IN, **mul_IN**, ne_IN, or_IN, pa_IN, pt_BR/PT, ta_IN, te_IN, ur_IN, yue_CN, zh_CN/HK/TW.
- DictationTranscriber.supportedLocales (54): adds ar_SA, ca_ES, cs_CZ, da_DK, el_GR, fi_FI, he_IL, hr_HR, hu_HU, id_ID, ms_MY, nb_NO, nl_BE/NL, pl_PL, ro_RO, ru_RU, sk_SK, sv_SE, th_TH, tr_TR, uk_UA, vi_VN (mostly legacy-dictation set; no bn/ta/te etc.).
- **Sinhala: NOT supported by either.** `supportedLocale(equivalentTo:)` returned nil for `si-LK` and `si` on both. ta_IN and hi_IN are supported by SpeechTranscriber (not Dictation for ta).
- Only 9 en_* locales were installed on this machine by default; others need download. The list is from macOS 27; the macOS 26 list may be smaller (e.g. India-locale additions may be newer). UNVERIFIED on 26: re-run `asr-poc locales` on a 26 machine/VM.
- `mul_IN` appears to be a multilingual (code-switching) Indian model; semantics undocumented in what I could read. UNVERIFIED. Worth a manual test with mixed Hindi/English audio.

### API surface [SDK]
- Types (all `anyAppleOS 26`): `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber`, `AssetInventory`, `AnalysisContext`, `AnalyzerInput`.
- 27-only additions (guard with `#available`/avoid in a 26 baseline): `AnalyzerInput.bufferDuration/bufferFormat` + `init(buffer: CMReadySampleBuffer)`, `SpeechAnalyzer.Options.ignoresResourceLimits`, `AnalyzerInputConverter`, `AssetInputSequenceProvider` (feed an AVAsset directly), `CaptureInputSequenceProvider` (AVCaptureDevice), `SFSpeechError.cannotConfigureAudioSystem`.
- Asset flow: `AssetInventory.status(forModules:)` -> `.unsupported/.downloading/.supported/.installed`; `assetInstallationRequest(supporting:)` -> `downloadAndInstall()` (has Progress); `reserve(locale:)`, `maximumReservedLocales`, `reservedLocales`. Assets are system-managed (not in the app container; shared, OS can evict). Requires network once per locale. [RAN] status path executed for installed en_US.
- Result types: `SpeechTranscriber.Result` has `range: CMTimeRange`, `text: AttributedString`, `alternatives`, `resultsFinalizationTime`, `isFinal` (via SpeechModuleResult). Reporting options: `.volatileResults`, `.fastResults`. Attribute option: `.audioTimeRange` (per-run `AttributeScopes.SpeechAttributes.TimeRangeAttribute`, i.e. per-word-ish timing). Presets: `.transcription`, `.transcriptionWithAlternatives`, `.timeIndexedTranscriptionWithAlternatives`, `.progressiveTranscription`, `.timeIndexedProgressiveTranscription`. TranscriptionOption: `.etiquetteReplacements` only.
- DictationTranscriber: ReportingOption `.volatileResults`, `.frequentFinalization`; ContentHint `.shortForm/.farField/.customizedLanguage(modelConfiguration:)` etc; TranscriptionOption `.punctuation/.emoji/.etiquetteReplacements`; same `.audioTimeRange`.
- Custom vocabulary: `AnalysisContext.contextualStrings[.general] = [...]` (bias list) and, DictationTranscriber only, `customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration)` (compiled custom LM with pronunciations). SpeechTranscriber has no customizedLanguage hint [SDK]. Effectiveness UNVERIFIED.
- Input: file via `SpeechAnalyzer(inputAudioFile:modules:)` / `analyzeSequence(from:)`, or `AsyncSequence<AnalyzerInput>` of AVAudioPCMBuffers for live; `bestAvailableAudioFormat(compatibleWith:)` to pick the format. `analyzeSequence` returns last CMTime; call `finalizeAndFinish(through:)`.
- No SFSpeechRecognizer authorization prompt was needed for the file path in the PoC (ran headlessly, en_US). Mic capture needs the usual mic permission; Info.plist usage strings still advisable. UNVERIFIED for live mic.

### Observed behavior [RAN, en-US, `say`-synthesized 5.6 s clip, preset `.timeIndexedProgressiveTranscription`]
- Volatile results arrive as a growing, revisable string with a fixed `range` (2.04-5.57) and are replaced by one FINAL per sentence-ish chunk. Volatile text can be wrong then corrected ("Whisper Kidit" -> final "whisper kit").
- Finalized result carried per-word `audioTimeRange` (e.g. ' Today' 2.04-2.16). Words come with a leading space and punctuation attached to the last word.
- On-device, no network after asset install. Latency/RTF: not measured (see benchmark plan).

### Notes
- Sinhala is a hard product gap for Apple engines; need Whisper (poor, see below) or a different strategy. Tamil/Hindi OK on SpeechTranscriber.
- Apple results do not provide per-word confidence or language ID; single fixed locale per transcriber (multi-locale via several analyzers/`mul_IN`).

## 2. WhisperKit (argmax-oss-swift)

- Repo: https://github.com/argmaxinc/argmax-oss-swift (MIT; NOTICES for third-party). Latest release **v1.1.1** (2026-10-08, via GitHub API). Products: `WhisperKit`, `TTSKit`, `SpeakerKit`, `ArgmaxOSS` (umbrella), CLI `whisperkit-cli`. Package.swift: swift-tools 5.10, platforms macOS 13 / iOS 16 (README says macOS 14+ / Xcode 16+; manifest says v13). Models on HF `argmaxinc/whisperkit-coreml`.
- [RAN] SwiftPM under Swift 6.4.2 / tools-version 6.2 / macOS 26 target: `swift build` succeeds, depends only on WhisperKit product. Language mode 6 in my target compiles clean (no warnings surfaced in my filtered output; not strict-audited).
- [RAN] Transcription with `openai_whisper-small_216MB` worked: language auto-detected "en", segments with word timings + probabilities. Note: must set `skipSpecialTokens = true` (default leaves `<|startoftranscript|>` tokens in segment text; PoC fixed). Model cached under `.model-cache/models/argmaxinc/whisperkit-coreml/` (total cache 387 MB at last check).
- Model variants on HF [WEB https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main, 2026-11-21]: tiny(.en), base(.en), small(.en)(_216MB), medium(.en), large-v2 (+_949MB, _turbo, _turbo_955MB), large-v3 (+_947MB, _turbo, _turbo_954MB), **large-v3-v20240930** (+_547MB, _626MB, _turbo, _turbo_632MB), distil-large-v3 (+_594MB, _turbo, _turbo_600MB). Suffix MB = size of the quantized (mixed-bit palettized) build; `_turbo` = the faster-decoder variants (Argmax's own "turbo" encoder-compiled/ANE builds), not to be confused with OpenAI large-v3-turbo (the 4-layer-decoder model; check model card before assuming). Sizes of non-suffixed folders (~3 GB for large) unmeasured here.
- Features [WEB README + SOURCE, 2026-11-21]: word timestamps (`DecodingOptions.wordTimestamps`), `detectLanguage(audioPath:)` (first 30 s; returns lang + probs), `DecodingOptions.language/detectLanguage/promptTokens/prefixTokens` (prompt tokens = vocabulary bias), VAD chunking (`chunkingStrategy`, `concurrentWorkerCount`), `AudioStreamTranscriber` actor (mic streaming with confirmed/unconfirmed segments, energy VAD), CLI `--stream`. Streaming is chunk-reprocessing (re-decodes a window), so live latency is seconds not ms; not verified here.
- Custom models: `WhisperKitConfig.modelFolder` (local CoreML folder, `download=false`), also pluggable `audioEncoder/textDecoder/featureExtractor`. [RAN] folder path code path compiled; folder load via variant name executed. Fine-tuned (e.g. Sinhala) models would need CoreML conversion via argmax `whisperkittools` (not tried).
- Sinhala: Whisper's tokenizer lists "si" [SOURCE Models.swift]. Zero-shot quality is believed very weak: I found no published zero-shot large-v3 Sinhala WER; a secondary source (HF card for a whisper-small Sinhala fine-tune) reports base whisper-small 130.86% WER vs 61.73% after fine-tuning [WEB https://friendli.ai/models/hlasith/whisper-sinhala-small, 2026-11-21, secondary, unverified]. Treat Sinhala via stock Whisper as "unusable until measured". Need a Sinhala test set (FLEURS si_lk is the natural one).

## 3. FluidAudio Parakeet TDT v3 (optional)
- https://github.com/FluidInference/FluidAudio, latest release v0.18.4 (2026-11-19). Apache-2.0 code (Sortformer diarizer is NVIDIA Open Model License). CoreML/ANE. README claims ~190x RTFx on M4 Pro (vendor claim, unverified here). Batch model; `SlidingWindowAsrManager` for pseudo-streaming; Parakeet EOU is English-only streaming. Min macOS not stated for TDT v3.
- Model nvidia/parakeet-tdt-0.6b-v3 [WEB https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3, 2026-11-21]: 0.6B params, CC-BY-4.0 (attribution required), 25 European languages (bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk), auto language detection, word/segment timestamps. **No Sinhala, Tamil or Hindi.**
- Role: fast English/European file transcription; strong candidate as fast batch engine vs Whisper. Not tried (kept downloads small).

## 4. Benchmark plan (orchestrator runs serially)
`spikes/asr/.build/release/asr-poc`:
1. `asr-poc apple <file> <locale>` and `asr-poc whisper <file> <variant> [lang]` on the same 60 s and 10 min clips (en, plus Tamil/Hindi from FLEURS); record wall time (`/usr/bin/time -l` for RSS), first-volatile latency (add timestamp printing if wanted), WER vs reference.
2. Variants: whisper small_216MB, large-v3-v20240930_626MB, large-v3-v20240930_turbo_632MB, distil-large-v3_turbo_600MB; Parakeet v3 via FluidAudio CLI.
3. Sinhala: FLEURS si_lk 100 utterances through whisper large-v3 variants (language `si`) for WER; Apple has no Sinhala.
4. Live mic (manual, UNVERIFIED): small harness to add later: AVAudioEngine tap -> `AsyncStream<AnalyzerInput>` with `bestAvailableAudioFormat`, measure time from speech to first volatile and to final. Needs mic permission; user must run.
5. Contextual strings test: transcribe a domain-terms clip with/without `AnalysisContext.contextualStrings`, and with Whisper `promptTokens`.

## ENGINE ROUTING TABLE (draft; speed/quality cells pending the benchmarks)

| Language | Live | File | Dictation | Notes |
|---|---|---|---|---|
| English (en-*) | Apple SpeechTranscriber (volatile) | Parakeet v3 (fast) or Whisper large-v3-v20240930_626MB (accuracy); Apple as zero-download default | Apple DictationTranscriber / SpeechTranscriber (short-form) | Apple assets for en preinstalled |
| European (de/fr/es/it/pt/ja/ko/zh) | Apple SpeechTranscriber | Whisper large-v3 variant or Parakeet v3 (EU languages only) | Apple | Check macOS 26 locale availability |
| Hindi | Apple SpeechTranscriber hi_IN (or mul_IN for code-switch, test) | Whisper large-v3 (compare to Apple) | Apple (hi_IN Dictation exists) | Parakeet no |
| Tamil | Apple SpeechTranscriber ta_IN | Whisper large-v3 (compare) | Apple Speech (Dictation lacks ta) | |
| Sinhala | None viable (Apple unsupported; Whisper streaming poor) | Whisper large-v3 `si`, quality unknown, label "experimental"; fine-tuned CoreML model is the real path | Not supported | Biggest gap |
| Other (ar, th, tr, ru...) | Apple DictationTranscriber where listed | Whisper large-v3 | Apple Dictation | |
| Unknown language | n/a | WhisperKit `detectLanguage` then route | n/a | |

Hardware dimension: 8 GB / base M1 -> prefer `_547MB/_626MB` or small, avoid concurrent live + file Whisper jobs; 16 GB+ M-Pro/Max -> large-v3 `_turbo` ok. Intel not supported by product. (Memory numbers unmeasured.)

## Recommendation
1. Default live + dictation engine: Apple SpeechAnalyzer/SpeechTranscriber (zero model weight, volatile+final, per-word timing, on-device). Use DictationTranscriber only where SpeechTranscriber lacks the locale (ar, ru, tr, th...).
2. File/batch + accuracy: WhisperKit with `large-v3-v20240930_626MB` (default), `_turbo_632MB` as the speed option; optional Parakeet TDT v3 (FluidAudio) as fast English/EU engine pending benchmark.
3. Sinhala is unsupported by Apple and unproven on Whisper: decide product stance now (experimental label, fine-tuned model, or drop). Build an `ASREngine` protocol (locale capability query, streaming + file entry points, word timings) so engines are swappable.
4. Build against macOS 26 API surface; wrap 27-only symbols in `#available(macOS 27, *)`.

## Routing-table rows
(see table above; machine-readable summary)
- en, live -> apple.speechTranscriber; en, file -> parakeet-v3 | whisper-large-v3-v20240930_626MB; en, dictation -> apple.speech/dictation
- eu+ja/ko/zh, live -> apple.speechTranscriber; file -> whisper-large-v3 | parakeet-v3 (EU only)
- hi, live -> apple hi_IN | mul_IN(test); file -> whisper-large-v3; dictation -> apple
- ta, live -> apple ta_IN; file -> whisper-large-v3; dictation -> apple speech
- si, live -> none; file -> whisper `si` (experimental); dictation -> none
- ar/ru/tr/th etc., live+dictation -> apple.dictationTranscriber; file -> whisper
- unknown -> whisper detectLanguage then route
- low-RAM (<=8 GB) -> small/_626MB; >=16 GB -> large-v3 turbo

## Sandbox/distribution flags
- None require non-sandboxed distribution from this spike. SpeechAnalyzer and WhisperKit (CoreML) run inside App Sandbox. Needs `com.apple.security.network.client` for model/asset downloads (WhisperKit HF download; AssetInventory is system-mediated), `com.apple.security.device.audio-input` + `NSMicrophoneUsageDescription` for live. WhisperKit models should be stored in the app container (Application Support) or bundled; HF download is a network egress at odds with "100% local", so offer user-initiated download or bundle.
- Apple speech assets are shared system storage, may be evicted, and cannot be pre-bundled; first use of a locale requires internet.
- Licensing: WhisperKit MIT; Whisper weights MIT; Parakeet v3 CC-BY-4.0 (needs attribution); FluidAudio Apache-2.0.
- System audio capture (meeting transcription) is out of scope here (see other spikes).

## Open questions for the user
1. Is Sinhala a launch requirement? If yes: accept experimental Whisper, invest in fine-tuning/conversion, or something else?
2. Is a first-run model/asset download acceptable under "100% local", or must models ship in the app bundle (size budget)?
3. Minimum RAM tier to support (8 GB machines)? Affects default Whisper variant.
4. Are Tamil/Hindi code-switching with English (mul_IN) cases important?
5. Can you run the manual PoCs (live mic, contextualStrings) and a macOS 26 machine/VM for locale-list comparison?
