# Diarization spike: FluidAudio vs SpeakerKit

Phase 0 research. Access date for all sources: 2026-11-21. Machine: M3 Pro, 18 GB, macOS 27.2.1, Xcode 27.2, Swift 6.4.2, SDK 27.2.
PoC: `spikes/diarization/` (SwiftPM, `swift build` passes with zero warnings in Swift 6 language mode). Raw outputs: `spikes/diarization/results/`.
No speed numbers were collected (shared CPU/GPU/ANE); only DER, memory, size and behaviour.

## 1. Candidates and sources

| | FluidAudio | SpeakerKit (argmax-oss-swift) |
|---|---|---|
| Source | https://github.com/FluidInference/FluidAudio (tag v0.18.4, released 2026-11-19, commit e0c6103) | https://github.com/argmaxinc/argmax-oss-swift (tag v1.1.1, released 2026-10-08, commit 9f99b5c) |
| SDK license | Apache-2.0 | MIT (plus vendored swift-transformers, Apache-2.0, see `NOTICES`) |
| Min platform | macOS 14 (manifest); tools 6.0 / 6.2 variant | macOS 13 (SpeakerKit); tools 5.10, `Package@swift-6.2.swift` uses `.v6` |
| SPM dependency footprint | none (one binary target, see 5) | `swift-argument-parser`; SpeakerKit target depends on **WhisperKit + ArgmaxCore** so WhisperKit is always compiled/linked |
| Models | HF `FluidInference/speaker-diarization-coreml` (offline VBx and legacy), `diar-streaming-sortformer-coreml`, `ls-eend-coreml`, `nemotron-3-diarization-coreml` | HF `argmaxinc/speakerkit-coreml` |

## 2. Feature comparison (from source, not marketing)

| Capability | FluidAudio 0.18.4 | SpeakerKit 1.1.1 |
|---|---|---|
| Offline (whole file) | Yes: `OfflineDiarizerManager` (pyannote Community-1 segmentation + WeSpeaker + PLDA + VBx). Also legacy `DiarizerManager` (pyannote 3.1 derived) | Yes: `PyannoteDiarizer` (segmenter + embedder + PLDA/VBx clustering) |
| Streaming / online | Yes: LS-EEND (10 spk, 100 ms steps), Sortformer (4 spk, 480 ms), Nemotron3 (8 spk), legacy chunked pyannote with `SpeakerManager` | **No.** `Diarizer` protocol takes only a whole `[Float]`; no Sortformer/streaming code exists in `Sources/SpeakerKit` (the protocol doc comment mentions `SortformerDiarizer`, but it is not in the OSS repo; Argmax's real-time product is the separate commercial "Pro" SDK per their README) |
| Overlapping speech | Offline keeps overlap by default (`exclusiveSegments` false); Sortformer/LS-EEND are end-to-end overlap-aware. Their own docs rate **LS-EEND**, not Sortformer, best on high overlap; Sortformer is the most stable but capped at 4 speakers and misses quiet speech | `useExclusiveReconciliation` default true (one speaker per frame) |
| Speaker embeddings | Offline result: `speakerDatabase: [String:[Float]]` (centroids, 256-d), per-chunk embeddings (`exposeChunkEmbeddings`), `embedSpans(...)` to embed arbitrary spans, `SpeakerManager` (Codable `Speaker`, `initializeKnownSpeakers`, `findSpeaker(with:)`, merge/permanence), Sortformer `enrollSpeaker`, `ConstrainedClusterAssignment` | `DiarizationResult.speakerCentroidEmbeddings`, `centroidCosineDistance`, `nearestSpeakerCentroid(to:)`. Raw embedder output, pre-PLDA, "no universal threshold, calibrate yourself" (source comment). No enrolment API, no embed-arbitrary-span API in the public surface |
| Transcript merge | Not built in (you align words to turns yourself) | Built in for WhisperKit results (`addSpeakerInfo`, `.subsegment`/`.segment`), RTTM export |
| Speaker count control | `clustering.numSpeakers/min/max` | `numberOfSpeakers`, `clusterDistanceThreshold`, `minClusterSize` |
| Model cache location | `prepareModels(directory:)` (honoured; used in PoC). **Caveat:** `VadManager(config:)` default writes to `~/Library/Application Support/FluidAudio`; the PoC passes `modelDirectory:` to redirect | `PyannoteConfig(downloadBase:)` (honoured; used in PoC) |
| HF token | Sends `Authorization: Bearer` only if `HF_TOKEN` env var is set (`Shared/Download/HFClient.swift`). Env was unset for all runs | Same pattern via `HubWrapper` (`HF_TOKEN`). Unset for all runs |

## 3. Accuracy (DER)

Method. Independent scorer: `pyannote.metrics` 4.2.0 in a private venv, run with `python -I` (`spikes/diarization/scripts/score_der.py`). Same reference RTTMs and UEMs for both engines. Never compare these against vendor-published DERs; FluidAudio's own docs say their scorer skips overlap and is not comparable to pyannote's.

Data. AMI meetings ES2004a, ES2004b, IS1009a from the AMI test split. Audio: HF dataset `FluidInference/ami-corpus-mirror` (card license cc-by-4.0, updated 2026-07-06), file `sdm/<id>.Mix-Headset.wav`. **This is the headset mix (close-talk, easy condition), not a distant microphone**, despite the folder name `sdm`. Reference: `BUTSpeechFIT/AMI-diarization-setup` (Apache-2.0) `only_words/rttms/test` + `uems/test`. AMI is CC-BY-4.0 (https://groups.inf.ed.ac.uk/ami/corpus/license.shtml, not re-read this session; verify before redistributing anything). Data stays in the gitignored `.model-cache/datasets/ami`. Only 3 meetings, 4 speakers each; treat as a smoke test, not a benchmark.

Both engines run with defaults, no speaker-count hint, debug build (accuracy unaffected).

| Meeting | Fluid A | SpeakerKit A | Fluid B | SpeakerKit B | Hyp speakers (ref=4): Fluid / SpeakerKit |
|---|---|---|---|---|---|
| ES2004a | 22.2 | 22.5 | 9.8 | 7.7 | 4 / 5 |
| ES2004b | 14.8 | 16.6 | 5.7 | 4.9 | 4 / 6 |
| IS1009a | 23.1 | 23.0 | 11.1 | 8.9 | 4 / 4 |
| Pooled | **18.1** | **19.2** | **7.5** | **6.2** | |

Protocol A = collar 0, overlap scored (strict). Protocol B = collar 0.25 s, overlap skipped (lenient, literature style). Miss dominates protocol A for both (9 to 19 points, mostly overlapped speech and the exclusive/limited overlap handling); confusion is only 1 to 6 points.

Reading. Statistically indistinguishable on this sample (same Community-1-family models underneath). SpeakerKit scores slightly better when overlap is excluded but **over-segments speakers on ES2004a/b (5 and 6 clusters for 4 people)**, which matters for a UI that names speakers. FluidAudio found the correct count on all three. Not covered: Sortformer, LS-EEND, Nemotron3, distant-mic audio, noisy/accented audio, more than 4 speakers.

## 4. Voice-profile (cross-session) matching

Test (`scripts/voice_match.py`): diarize ES2004a and ES2004b (same 4 participants, same series), map each hypothesis speaker to the reference person by maximum overlap, then compare centroid cosine distances between meetings.

| | same-person pairs | different-person pairs |
|---|---|---|
| FluidAudio `speakerDatabase` | n=4, **max 0.076** | n=12, **min 0.678**, median 0.929 |
| SpeakerKit `speakerCentroidEmbeddings` | n=8, 4 pairs 0.03 to 0.07 but 4 pairs **0.50 to 0.89** (caused by split/impure clusters: purity 0.58 to 0.63) | n=22, min 0.591, median 0.920 |

Takeaways.
- Centroids from clean, pure clusters separate people very well (gap of >0.5 on this data). A cosine-distance threshold near 0.3 to 0.4 would have given zero errors here, but n is tiny, same room/mic chain, same speaker series, so the real threshold must be calibrated on more data (open question).
- SpeakerKit's over-segmentation produces extra clusters that match nothing; matching must be tolerant (compare every cluster, ignore low-purity ones, do not require 1:1).
- Profiles are bound to the embedding model version. FluidAudio: WeSpeaker Community-1 256-d from the `speaker-diarization-coreml` Community-1 set. SpeakerKit: pyannote-v3-era embedder in raw (pre-PLDA) space. Store `embeddingModel` + dimension with each profile and re-enrol on model change. The PoC `DiarOutput.embeddingModel` field models this.
- FluidAudio is the better enrolment base: `embedSpans` lets the app embed a known-speaker snippet (e.g. the user's mic VAD spans) without running a full diarization; `SpeakerManager` is already `Codable`. SpeakerKit has no equivalent public hook (only centroids from a finished run).
- Embeddings are biometric data (see Open questions).

## 5. Licensing and attribution (per API path, not per SDK)

The "FluidAudio SDK is Apache-2.0, models CC-BY-4.0" premise is only partly right. The model licence depends on which API is used:

| Path | HF repo | Licence (primary source) | Obligations |
|---|---|---|---|
| FluidAudio `OfflineDiarizerManager` (Community-1) | `FluidInference/speaker-diarization-coreml` | Card says `license: other` / "scoped-cc-by-4.0"; NOTICE.md scopes CC-BY-4.0 to the Community-1 artifacts (Segmentation, FBank, Embedding, PLDA, PldaRho, plda/xvector json). Upstream `pyannote/speaker-diarization-community-1` is CC-BY-4.0 (gated on HF, but the Fluid copy is not). PLDA params from BUT Speech@FIT, CC-BY-4.0 incl. commercial | Attribute pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference; link CC-BY-4.0; say the files are modified Core ML conversions; keep citations from the repo README |
| FluidAudio legacy `DiarizerManager` | same repo, `pyannote_segmentation`/`wespeaker*` | "Under their own upstream licenses" (NOTICE.md table, derived from pyannote 3.1). Not covered by the CC-BY scope | Avoid in the product; use Community-1 path |
| Sortformer | `FluidInference/diar-streaming-sortformer-coreml` (card: cc-by-4.0) | **Conflict recorded:** FluidAudio's `Sortformer.md` says NVIDIA Open Model License; Fluid's HF card says cc-by-4.0; NVIDIA's own repos: `diar_streaming_sortformer_4spk-v2` = cc-by-4.0, `...-v2.1` = `nvidia-open-model-license`. The Fluid repo ships both v2 and v2.1 variants | If v2.1 is shipped: NVIDIA Open Model License (commercial use OK; redistributing the model requires the licence text plus a Notice file reading "Licensed by NVIDIA Corporation under the NVIDIA Open Model License"; litigation termination clause; guardrail-bypass termination; indemnity). Summary obtained via WebFetch of https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/ ; read the full text before shipping. Pinning to v2 (CC-BY-4.0) avoids it |
| LS-EEND | `FluidInference/ls-eend-coreml` | MIT (card) | Attribution; trained on AMI/CALLHOME/DIHARD (upstream data licences not audited) |
| Nemotron3 diarizer | `FluidInference/nemotron-3-diarization-coreml` | `openmdw-1.1` (card). Not audited | Review OpenMDW terms before use |
| Silero VAD (FluidAudio VAD) | `FluidInference/silero-vad-coreml` | MIT (card) | Attribution |
| SpeakerKit | `argmaxinc/speakerkit-coreml` | Card: cc-by-4.0 ("models have CC BY 4 license"). Folder READMEs point to upstream licences: embedder = WeSpeaker pretrained-model licence, segmenter = `pyannote/segmentation-3.0` (MIT upstream), clusterer = BUT VBx licence | CC-BY-4.0 attribution; audit WeSpeaker and VBx upstream terms. **Discrepancy recorded:** SpeakerKit README says "Pyannote v4 (community-1)", but `PyannoteConfig.swift` defaults to `pyannote-v3` segmenter and embedder with only the PLDA clusterer at `pyannote-v4`. It is not the Community-1 stack |
| SDK code | FluidAudio Apache-2.0 (+ `ThirdPartyLicenses/` fastcluster, VBx, etc. must be reproduced in the app's acknowledgements); SpeakerKit MIT + Apache-2.0 swift-transformers `NOTICES` | Ship an acknowledgements screen / `THIRD_PARTY_NOTICES` file |

Supply chain facts. FluidAudio 0.18.4 declares a remote **binary target** (`NemoTextProcessing.xcframework`, from `FluidInference/text-processing-rs` v0.3.4, checksum-pinned). With `traits: ["Diarizer"]` SwiftPM still **downloads** the xcframework (`.build/artifacts/fluidaudio/...`, ~8 MB) but the trait stops it being **linked**: `nm` on the built executable finds zero `text_processing_rs`/`rustfst` symbols. Dependency pins used: FluidAudio exact 0.18.4, argmax-oss-swift exact 1.1.1, swift-argument-parser 1.8.2.

## 6. Swift 6 / SPM integration

- PoC manifest: tools 6.2, `.macOS("26.0")`, every target `swiftLanguageMode(.v6)`, exact version pins. `swift build` succeeded; a forced rebuild of the three PoC targets printed no warnings or errors (verified by grepping the build log for `warning|error`).
- Traits require tools 6.2+ (FluidAudio's own README: "Swift 6.2+ / Xcode 26+"). Enable only `Diarizer` to drop TTS and Nemo.
- FluidAudio sources compile in Swift 6 mode (tools 6.0 manifest). `OfflineDiarizerManager` is a non-Sendable `final class` that stores models in `nonisolated(unsafe)` vars ("only written during initialization"). The PoC wraps it in an actor that creates and uses it internally, which type-checks cleanly. Public result types (`DiarizationResult`, `TimedSpeakerSegment`, `Speaker`) are `Sendable`. `SortformerDiarizer` and `DiarizerTimeline` are classes (not Sendable); isolate them in an actor in the app.
- SpeakerKit: the default manifest (tools 5.10) enables `StrictConcurrency` experimental only; `Package@swift-6.2.swift` selects `.v6`. Core classes (`SpeakerKitDiarizer`, `PyannoteConfig`, `SpeakerSegmenterModel`) are `@unchecked Sendable`. The PoC holds `SpeakerKit` inside an actor; no diagnostics. Both libraries export `DiarizationResult`/`Diarizer`, so import each in a separate module (as the PoC does behind a `DiarizationEngine` protocol). That seam is also what the app needs to swap backends.
- Build cost: SpeakerKit pulls WhisperKit into the link. Both engines together gave a ~1.0 GB `.build` in debug.

## 7. Memory and model size

Measured with `/usr/bin/time -l` on the **debug** PoC binary, 3 AMI files (18 to 35 min of 16 kHz mono; the Float32 sample array alone is 70 to 150 MB, so numbers are pessimistic for a release build that streams from disk). One process per run, sequential.

| | Max RSS | Peak memory footprint | Models on disk |
|---|---|---|---|
| FluidAudio offline | 374 to 387 MB | 0.89 to 1.06 GB | 21 MB (`.model-cache/fluidaudio/speaker-diarization`) |
| SpeakerKit | 584 to 831 MB | 0.63 to 0.88 GB | 11 MB (W8A16 variants) |

Both fit comfortably in 18 GB alongside an ASR model; the dominant memory in the app will be ASR, not diarization. SpeakerKit's RSS grew with meeting length/speaker count (831 MB on the 75 MB ES2004b file) which is consistent with its parallel segmenter/embedder workers (defaults: 4 segmenter workers, up to 8 embedders); not investigated further. Fluid's Sortformer and LS-EEND memory was **not measured** (not run). FluidAudio's docs claim Sortformer high-context fp16 ~ hundreds of MB and offer a palettized option (docs, unverified).

## 8. Dual-track meeting design (mic = "You", system/remote = diarized)

Proposal, implemented as `diar-poc dualtrack`:
1. Mic track: VAD only (FluidAudio Silero VAD, 256 ms hops, spans labelled "You"); no diarization, no speaker-count ambiguity for the local user.
2. Remote/system track: offline (post-meeting) or streaming (live) diarization.
3. Merge by timestamp; "You" can overlap remote speakers legitimately (cross-talk).
4. Bleed guard: when the user is **not on headphones**, the mic picks up remote voices. PoC applies a crude cross-track gate (drop mic spans overlapping >50% with remote speech), but this also drops real interruptions. Proper solution: AEC (Apple Voice Processing I/O on the mic path, or a reference-based echo canceller) before VAD. Treat headphone detection plus VPIO as a Phase 3 question.
5. Voice profile for "You": enrol from mic VAD spans (FluidAudio `embedSpans`), store locally, use to label the user in in-room recordings where one mic captures several people.
6. In-room / hybrid meetings (several people at one mic) fall back to single-track diarization plus the "You" profile match.

Smoke test status: the `dualtrack` command ran end-to-end (VAD model downloaded into the `.model-cache` redirect; 4 remote speakers found) using two unrelated AMI headset mixes as stand-in "mic" and "remote" tracks. That only proves wiring, **not accuracy**. Real mic+system capture needs the Phase 1 capture PoC (ScreenCaptureKit/CoreAudio tap, mic permission, screen-recording or audio-capture permission): **UNVERIFIED pending user run** with real captured stereo files:
```
cd spikes/diarization && swift build -c release
.build/release/diar-poc dualtrack mic.wav system.wav --out results --cache ../../.model-cache --engine fluid
```

## 9. Streaming status (what actually ships)

- FluidAudio: streaming is first-class (LS-EEND default recommendation, Sortformer, Nemotron3). Not exercised in the PoC (time-boxed; offline path was the Phase 0 priority). Their own comparison table lists "remembering speakers across meetings": Sortformer Great, DiarizerManager Best, LS-EEND Good; pre-enrolment: Sortformer Best, LS-EEND Weak. Sortformer's 4-speaker cap is a hard limit for larger meetings; LS-EEND allows 10.
- SpeakerKit OSS: offline only. A live "who is speaking" UI would need either FluidAudio streaming or a post-hoc relabel after the meeting.
- Vendor benchmark claims (not reproduced, not comparable to the table above): FluidAudio docs report AMI SDM subset DER offline VBx 12.0 %, LS-EEND 25.7 %, Sortformer 34.3 % with a lenient scorer; Sortformer high-context 20.6 to 31.7 % depending on variant. Treat as indicative only.

## 10. Reproduction

```
cd spikes/diarization && swift build
P=.build/debug/diar-poc
$P diarize fluid      <audio.wav> --out results --cache ../../.model-cache
$P diarize speakerkit <audio.wav> --out results --cache ../../.model-cache
$P match results/fluid-A.json results/fluid-B.json       # centroid distance matrix
python -I scripts/score_der.py <ref_dir> <uem_dir> results fluid <meeting>...   # needs pyannote.metrics in a venv
python -I scripts/voice_match.py <ref_dir> results fluid ES2004a ES2004b
```
First run needs network (HF model download); later runs can be offline.
Sample data was fetched from the HF AMI mirror and the BUT RTTM repo into `.model-cache/datasets/ami` (gitignored).

## Recommendation

Use **FluidAudio (Community-1 offline path + `embedSpans`/`SpeakerManager` for voice profiles)** as the diarization backend, behind a `DiarizationEngine` protocol so SpeakerKit (or others) can be swapped in.
- Accuracy is equal within noise to SpeakerKit on 3 headset-mix AMI meetings (pooled DER 18.1 vs 19.2 strict, 7.5 vs 6.2 lenient), but FluidAudio got the right speaker count every time and cleaner centroids.
- It is the only one with streaming, enrolment-capable embedding APIs, and no forced WhisperKit dependency; SpeakerKit's only unique plus is built-in WhisperKit transcript merging, which is trivial to reimplement.
- Use SPM trait `Diarizer` only. Pin exact versions. Do not use the legacy `DiarizerManager` path (unclear licences).
- Pin Sortformer to NVIDIA v2 (CC-BY-4.0) if used at all, or prefer LS-EEND (MIT) for live use; decide after a streaming spike in Phase 1.
- Voice profiles: store centroid + embedding-model id + dimension; threshold to be calibrated on more data (start with cosine distance <= 0.35 as a *hypothesis*, never auto-merge without a user-confirmable UI).

## Routing-table rows

| Task | Engine | Notes |
|---|---|---|
| Post-meeting diarization (file, any length) | FluidAudio `OfflineDiarizerManager` (Community-1 VBx) | Remote/system track only in dual-track mode; mic track = VAD + "You" |
| Live speaker labels during a meeting | FluidAudio LS-EEND (default) or Sortformer v2 | Not validated; Phase 1 streaming spike |
| Cross-session speaker identity (voice profiles) | FluidAudio centroids/`embedSpans` + `SpeakerManager`, own storage | Store model id with each profile; user-confirmed matching |
| Fallback / A-B comparison | SpeakerKit via `DiarizationEngine` adapter | Offline only; over-segments; links WhisperKit |
| Mic-track "You" detection | FluidAudio Silero VAD (+ AEC upstream) | AEC/headphone handling open |

## Sandbox/distribution flags

- Runtime model download from `huggingface.co` needs `com.apple.security.network.client`. Alternative: bundle the ~21 MB (Fluid) models in the app and load offline (supported via `OfflineDiarizerModels.load(from:)`); this also removes the HF-availability dependency.
- Model caches must be redirected into the app container (`prepareModels(directory:)`, `PyannoteConfig(downloadBase:)`, **and** `VadManager(modelDirectory:)`; its default is `~/Library/Application Support/FluidAudio`, which a first PoC run wrote outside the allowed paths; that stray folder was deleted).
- The Core ML compile step for `.mlpackage` (if ever used instead of precompiled `.mlmodelc`) writes to temp; the precompiled `.mlmodelc` used here avoids this.
- Mic capture: `NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input`. System-audio capture (ScreenCaptureKit or CoreAudio process tap) needs its own TCC permission and may need the user to grant it each OS cycle. Not verified here.
- Mac App Store distribution: unaffected by diarization libraries themselves; third-party notices (Apache-2.0, CC-BY-4.0, MIT, possibly NVIDIA) must appear in-app. Binary target `NemoTextProcessing` is downloaded at resolve time though not linked.
- Voice embeddings are biometric identifiers (GDPR Art. 9, Illinois BIPA, etc.). Store in the app container, encrypt at rest if feasible, never sync without opt-in, provide "delete voice profile".

## Open questions for the user

1. Is live (during-meeting) speaker labelling a v1 requirement, or is post-meeting diarization sufficient? This decides whether LS-EEND/Sortformer streaming needs a spike.
2. Should "You" be assumed to be the mic track only, or must the app also handle in-room meetings with several people on one mic (and users without headphones)?
3. Is a bundled-models (offline, no `network.client` entitlement for models) distribution preferred over first-launch download?
4. Voice profiles: opt-in per person? Retention and deletion policy? Are remote participants' voices (other people's biometrics) allowed to be stored at all, or only the user's own?
5. Typical meeting size: more than 4 remote speakers (rules out Sortformer)? Typical audio source: headset, laptop mic, or room mic (my test used the easy headset mix)?
6. Acceptable licensing posture: CC-BY attribution in an About screen is fine? NVIDIA Open Model License (Sortformer v2.1) acceptable, or restrict to CC-BY/MIT/Apache models?
7. Can I get 2 to 3 of your own recorded meetings (with consent of participants) to calibrate the voice-match threshold and measure real-world DER? AMI headset audio overstates accuracy.
