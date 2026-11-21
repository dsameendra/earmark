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

- FluidAudio: streaming is first-class (LS-EEND default recommendation, Sortformer, Nemotron3). Exercised in section 11 (LS-EEND, Sortformer v2, legacy pipeline; Nemotron3 not run). Their own comparison table lists "remembering speakers across meetings": Sortformer Great, DiarizerManager Best, LS-EEND Good; pre-enrolment: Sortformer Best, LS-EEND Weak. Sortformer's 4-speaker cap is a hard limit for larger meetings; LS-EEND allows 10.
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

## 11. Live / streaming (user requirement: live speaker labels in v1)

Added after the coordinator follow-up. Access date 2026-11-21. FluidAudio 0.18.4. Same three AMI headset-mix meetings, same independent scorer and protocols as section 3. Audio was fed in 100 ms chunks as fast as possible (no real-time pacing, **no timing recorded**; other agents were using the machine). Latency below is in **audio time** (seconds of audio that had been fed when a label appeared), not wall clock.

Harness: `diar-poc stream <kind> <audio>` (`FluidStreamEngine`), `scripts/run_stream_matrix.sh` (serial matrix with `/usr/bin/time -l`), `scripts/stream_eval.py`, `diar-poc stream-dual` + `scripts/dual_eval.py`. Raw logs and per-update JSON: `spikes/diarization/results/stream/`, `.../results/dual/`. Kinds: `lseend-ami`, `lseend-dihard3`, `sortformer-fastV2`, `sortformer-balancedV2`, `legacy`.

### 11.1 Accuracy vs offline, stability, latency, memory

| Engine (variant) | Max speakers | DER A strict (ES2004a / ES2004b / IS1009a / pooled) | DER B lenient pooled | Disagreement with offline VBx output (strict DER, pooled) | Min dominant-slot share |
|---|---|---|---|---|---|
| Offline VBx (section 3, for reference) | none | 22.2 / 14.8 / 23.1 / **18.1** | 7.5 | 0 | n/a |
| LS-EEND `.ami` (100 ms step) | **4** | 18.0 / 11.3 / 27.2 / **15.7** | 8.5 | 17.1 | 0.55 |
| LS-EEND `.dihard3` | 10 | 38.5 / 29.4 / 49.6 / 35.3 | 29.3 | 36.0 | 0.39 |
| Sortformer v2 "fast" (`fastV2`) | 4 | 28.8 / 23.6 / 26.4 / 25.3 | 19.8 | 29.0 | 0.50 |
| Sortformer v2 "balanced" (`balancedV2`) | 4 | 28.5 / 20.7 / 32.1 / 24.6 | 19.0 | 27.9 | 0.46 |
| Legacy streaming `DiarizerManager`, 10 s chunks, threshold 0.7 | none (found 4/7/5 for 4/4/4) | 25.2 / 33.6 / 58.9 / 36.1 | 27.0 | 27.9 | 0.39 |

Notes on reading the table.
- **The LS-EEND `.ami` number is optimistic.** That checkpoint is trained on AMI (the test meetings are held out, but the domain, headsets and room setups are the same). The generic `.dihard3` checkpoint, which is what you would use for unknown audio, is far worse here (35.3 vs 15.7). Treat 15.7 as a best case for AMI-like meeting audio and 35 as the generic floor. Our own recordings are needed (open question).
- Sortformer v2 misses speech: most of its error is **missed detection** (20 to 26 points on ES2004a/b), consistent with FluidAudio's own docs ("trained to ignore background conversations", misses quiet speech). Very few false alarms or confusions on the 4-speaker meetings. Only the **v2 weights** were run (see 11.3 for why). v2.1 was not evaluated.
- Legacy pipeline: with the documented streaming threshold of 0.8 it collapsed all speech into **one** speaker (pooled DER 66.4); with the default 0.7 it over-segments (7 speakers on ES2004b). It is also the heaviest on memory. Do not use for live labels.
- "Disagreement with offline" is the strict DER of the live output scored against the offline VBx hypothesis. It is a proxy for how much the transcript labels would change at the finalization pass.
- Dominant-slot share = for each reference person, the share of their speech carried by their most-used output slot (1.0 = never changes slot). All end-to-end models keep slot identities reasonably stable (typical 0.8) but every one of them has at least one person split across slots at 0.4 to 0.55 (these are minor speakers or ones who interrupt/overlap).

Label stability (flips).
- Finalized segments are immutable in all FluidAudio streaming diarizers (no retroactive relabel); flips show up as the same person appearing under a different slot later (low dominant-slot share), not as rewrites.
- Tentative (not yet final) labels: Sortformer revised 4.4% (balanced) to 5.5% (fast) of tentative frames before finalization. LS-EEND `.ami` and `.dihard3` revised 0.0% in my measurement (first tentative view equals final slot set at 0.1 s resolution). I did not investigate why LS-EEND tentative output never changes; either the tentative window is effectively a lookahead of already-stable frames or my log (first view only) hides revisions. Treat as measured, unexplained.
- Slot identities do not carry names. Names must be re-attached by the app (voice profile / user rename) and survive across reconnects only if the app stores the slot-to-name mapping.

Latency to label (audio time).

| Engine | First (tentative) label | Final label |
|---|---|---|
| LS-EEND | about 1.1 s after the speech (p50 and p90 identical at 1.10 s in this log, i.e. one fixed look-ahead of about 1.0 s plus the 100 ms chunk) | about 1.1 s (fixed) |
| Sortformer v2 fast / balanced | tentative at p50 0.4 s, p90 0.8 to 0.9 s after speech start | p50 0.9 s, p90 1.1 s after segment end |
| Legacy | none (chunk-batched) | up to the chunk length (p90 7.3 s, max 9.0 s with 10 s chunks) |

All three end-to-end/streaming engines processed faster than real time in a debug build while the machine was shared, but **no timings were recorded**. Serial timing script: run `scripts/run_stream_matrix.sh` on an idle machine and prepend `time` per command (comment in the script).

Memory (`/usr/bin/time -l`, debug build, whole-file audio array is resident which is 20 to 150 MB of it, so deltas between engines are only indicative).

| Engine | Max RSS | Peak footprint | Models on disk |
|---|---|---|---|
| LS-EEND `.ami` / `.dihard3` | 119 to 311 MB | 111 to 304 MB | about 43 MB per variant |
| Sortformer v2 fast / balanced | 137 to 642 MB (first-run Core ML compile outlier; 312 MB on ES2004b) | 181 to 304 MB | about 240 MB per variant (two variants cached = 483 MB) |
| Legacy streaming | 410 to 918 MB (1.26 GB on a first, collapsed-cluster run) | 470 to 979 MB | about 13 MB |

In the app the audio would be streamed, not held, so LS-EEND is on the order of its 43 MB model plus buffers; Sortformer is the heavy one at roughly 240 MB of weights.

### 11.2 Maximum speakers

LS-EEND slots per variant (from FluidAudio docs and confirmed by `numSpeakers` in the logs): `.ami` 4, `.callhome` 7, `.dihard2` 10, `.dihard3` 10. Sortformer: fixed 4. Nemotron3: 8 per FluidAudio docs (not run). Legacy: unbounded. So **live labels for meetings above 4 remote speakers means either `.dihard3` (accuracy was poor on AMI here) or the legacy pipeline (unstable)**, or accepting that slots 5+ fall into the nearest speaker. The offline finalization pass has no cap.

### 11.3 Sortformer licence (read from source text, not a summary)

Sources read in full: NVIDIA Open Model License Agreement at https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/ (page text "Last Modified: October 24, 2025", fetched raw with curl and read in full); `nvidia/diar_streaming_sortformer_4spk-v2.1` model card (`license: other`, `license_name: nvidia-open-model-license`, section "Licence" links to that agreement); `nvidia/diar_streaming_sortformer_4spk-v2` model card (`license: cc-by-4.0`; section "Licence": "License to use this model is covered by the CC-BY-4.0 ... By downloading the public and release version of the model, you accept the terms and conditions of the CC-BY-4.0 license."); `FluidInference/diar-streaming-sortformer-coreml` card (`license: cc-by-4.0`, `base_model: nvidia/diar_streaming_sortformer_4spk-v2.1`, `base_model_relation: finetune`, ships both v2 and v2.1 variants).

What the agreement says (my reading of the text; not legal advice):
- Models are commercially usable; derivative models may be created and distributed; NVIDIA claims no ownership of outputs. The grant is perpetual, worldwide, royalty-free, **revocable** as stated in 2.1.
- Termination triggers: (a) the licensee files copyright/patent litigation alleging the Model or a Derivative Model infringes; (b) bypassing or weakening any "Guardrail" (technical limitation, safety guardrail, security or DRM mechanism) in the Model without a substantially similar replacement. Nothing in Sortformer's streaming conversion obviously involves a guardrail, but "technical limitation" is broad; worth legal review.
- NVIDIA may update the agreement "at any time"; the licensee must comply with the update or stop using and distributing the model. This is an ongoing unilateral-change risk for a shipped product.
- Must follow NVIDIA's Trustworthy AI terms (https://www.nvidia.com/en-us/agreements/trustworthy-ai/terms/, **not read**).
- Redistribution (which bundling the model in the app or serving it from our CDN would be): give recipients a copy of the agreement and include a "Notice" text file with exactly: "Licensed by NVIDIA Corporation under the NVIDIA Open Model License". The "Built on NVIDIA Cosmos" clause applies only to Cosmos models, not Sortformer. If the app only downloads the models at runtime from Fluid's Hugging Face repo, the distribution is by Fluid, but the in-app notice is still prudent.
- Indemnity: the licensee must indemnify NVIDIA for third-party claims arising from use or distribution of the Model, Derivative Models **or outputs**. Warranty and liability are fully disclaimed. Governing law Delaware, courts in Santa Clara County. Export-control compliance required.
- The Core ML conversion by Fluid is a "Derivative Model"; any rights Fluid grants cannot exceed NVIDIA's.

Conclusions.
1. **v2.1 weights are under the NVIDIA Open Model License** (per NVIDIA's own card), with the obligations above. FluidAudio's `Sortformer.md` says the same.
2. **v2 weights are CC-BY-4.0 per NVIDIA's own v2 card.** CC-BY-4.0 needs attribution, a licence link, and a change notice, with none of the revocation, indemnity or unilateral-update terms. All Sortformer numbers in this report used the v2 weights (`fastV2`, `balancedV2`; files `Sortformer_v2.mlmodelc`, `SortformerNvidiaLow_v2.mlmodelc`).
3. **Conflict to flag:** Fluid's card labels the whole repo `cc-by-4.0` while naming v2.1 (NVIDIA OML) as base model. That label cannot override NVIDIA's licence for the v2.1 conversions. Do not rely on Fluid's label for v2.1. Pin to v2 if Sortformer is used; ask Fluid/NVIDIA if the v2 licence status is ever in doubt (one open item: whether a later NVIDIA edit changes the v2 card).
4. Practical: the licence question is **not a blocker** because the recommended live engine (LS-EEND, MIT per Fluid's card) avoids it; Sortformer v2 is a clean fallback if we accept CC-BY attribution.

### 11.4 Dual-track live (mic = "You", remote diarized live)

`diar-poc stream-dual <mic.wav> <remote.wav> [--kind lseend-ami|sortformer-fastV2] [--bleed g] [--gate on|off]`: remote track goes to the streaming diarizer; mic track goes through live Silero VAD (`VadManager.processStreamingChunk`, 256 ms frames, hysteresis state machine) and every closed span is labelled "You". Both tracks are fed in lockstep. **No real two-track recording was available**, so this is a synthetic test: mic = IS1009a (a different meeting, all speakers collapsed to "You"), remote = ES2004a. Reference = ES2004a speakers plus the union of IS1009a speech as "You". Speaker bleed is simulated by mixing 0.2 x remote into the mic. Wiring and failure modes only; **not real-world accuracy, UNVERIFIED pending real captured stereo**.

| Case | Result |
|---|---|
| LS-EEND `.ami` remote, no bleed, no gate | DER 13.6%; "You" precision 0.92, recall 1.00 |
| Same, bleed 0.2, no gate | DER 13.7%; "You" precision 0.91, recall 1.00 (bleed did not hurt when the real mic speaker was loud) |
| Silent mic + 0.2 bleed, no gate | **774 s of false "You"** (75 spans) over about 17 min; VAD cannot tell bleed from the user |
| Silent mic + 0.2 bleed, gate on (drop "You" spans >50% overlapped by remote speech) | 6 s false "You" |
| Real "You" with the gate on (cross-talk is 100% in this synthetic case) | DER 51.3% ("You" recall **0.13**): the gate deletes genuine "You" speech that overlaps remote speech |
| Sortformer v2 remote, gate on | DER 52.5% (same gate failure; more remote turns because it reports finer segments) |

Conclusions.
- Bleed is a real problem: without AEC or gating, any speaker output audible to the mic becomes "You". The 0.5-overlap gate is the wrong tool: it fixes bleed and destroys real interruptions. The synthetic case exaggerates cross-talk (two continuous meetings), but real meetings also have it.
- Right design: acoustic echo cancellation upstream of VAD (Apple Voice Processing I/O on the mic path, since we know the remote reference), plus an **energy/level gate relative to the remote track** instead of time overlap, plus "You" voice-profile verification (speaker embedding of the mic span matches the user's enrolled voice) so bleed from a remote speaker fails the voice check. Headphones disable the problem. All of this is Phase 1/3 work; the PoC only shows why it is needed.
- The remote diarizer runs independently of the mic, so "You" cannot create a fifth speaker slot and does not consume one of the 4 LS-EEND/Sortformer slots. That is a real advantage of dual-track for the 4-slot models.
- If the user is on speakers (no AEC), fall back to single-track diarization on a mixed signal plus a "You" voice-profile match.

### 11.5 Reconciling live labels with the offline finalization pass

Observed data points: strict disagreement between LS-EEND `.ami` live output and offline VBx is 17% (pooled; 11% on the easiest meeting, 33% on the hardest); Sortformer 28 to 29%. So a visible relabel at finalization is normal, not exceptional.

Recommended design.
1. **Two label layers.** Each transcript segment stores `liveSpeakerSlot` (engine, slot index, confidence, model id) and `speakerID` (canonical, user-facing). During the meeting `speakerID` = provisional ("Speaker 1 (live)"). Never rewrite the words, only the speaker field.
2. **Record audio during the meeting** (per track, local file) so the offline pass is possible. Without it, no finalization pass.
3. **At meeting end run offline VBx** (Community-1) on the remote track; the "You" track is never diarized.
4. **Map live to offline** by maximum time overlap (Hungarian assignment, same as the scorer): each live slot maps to the offline cluster that holds most of its speech. Carry user edits and any voice-profile names across the mapping. A live slot that splits into two offline speakers (dominant share below about 0.7) keeps the user name only on the dominant part and marks the other as needing review. Offline wins on conflicts.
5. **Voice profiles bridge sessions**: after the offline pass, match offline centroids (section 4) to stored profiles to propose names. Do not auto-apply a name below a high-confidence threshold (threshold still to calibrate).
6. **UI honesty.** Show live labels as provisional (for example lighter chip) and animate to the final labels with a short "refining speakers" state; offer "keep live labels" only as a fallback if the offline pass fails.
7. Edge cases: live engine capped at 4 speakers while the offline pass finds 6 (labels for speakers 5 and 6 appear only after finalization); a slot that never maps (false alarm) is dropped.

### 11.6 Recommendation for live

- **Primary live engine: FluidAudio LS-EEND, `.ami` checkpoint for meetings (<=4 remote speakers), 100 ms step.** Best live accuracy here by a wide margin, fixed about 1 s look-ahead, MIT-licensed model, 43 MB, low memory, no licence ceremony. Caveats: in-domain optimistic number, 4-slot cap, more flips than Sortformer in some meetings (minor speakers).
- **Fallback: Sortformer v2 (CC-BY-4.0 weights only, `fastV2`)** for stability-first behaviour (tentative labels arrive earlier, about 0.4 s median, and revise only about 5% of frames) when LS-EEND on real audio underperforms. Cost: 240 MB, 4 speaker cap, misses quiet and overlapped speech, licence caveats.
- **Beyond 4 speakers:** no good live option found. Either LS-EEND `.dihard3` (10 slots, weak on AMI) or degrade live to "unknown speaker" and rely on the offline pass.
- **Do not use** the legacy chunked `DiarizerManager` pipeline for live labels (collapse/over-segmentation, latency of seconds, heaviest memory).
- Everything above rests on 3 headset-mix meetings; **the choice must be re-validated on the user's own recorded meetings before Phase 3**, including the unverified real-hardware dual-track capture.

## Recommendation

- **Offline / finalization diarization: FluidAudio `OfflineDiarizerManager` (Community-1 VBx)** plus `embedSpans` / `SpeakerManager` for voice profiles, behind a `DiarizationEngine` protocol. SpeakerKit stays a swappable fallback (accuracy equal within noise, over-segments, offline only, links WhisperKit).
- **Live (v1 requirement): FluidAudio LS-EEND `.ami` (primary), Sortformer v2 CC-BY weights `fastV2` (fallback).** Live labels are provisional and get reconciled by the offline pass on the recorded audio (section 11.5). Legacy chunked pipeline is out.
- Dual-track: mic = live VAD "You" with AEC and voice-profile verification (the PoC time-overlap gate is not adequate); remote track diarized live and again offline.
- Use SPM trait `Diarizer` only; pin exact versions; avoid legacy `DiarizerManager` model path (unclear licences). Voice profiles: store centroid + embedding model id + dimension; calibrate threshold on more data; never auto-merge without a confirmable UI.
- Everything is validated only on 3 AMI headset meetings; re-validate on the user's own recordings.

## Routing-table rows

| Task | Engine | Notes |
|---|---|---|
| Live speaker labels during a meeting (remote track, <=4 speakers) | FluidAudio LS-EEND `.ami`, 100 ms step | Provisional labels; about 1 s look-ahead; 43 MB; MIT model |
| Live fallback / stability-first | FluidAudio Sortformer v2 (`fastV2`, CC-BY-4.0 weights) | 4 speakers max, 240 MB, misses quiet/overlapped speech; do not ship v2.1 without NVIDIA OML review |
| Live with more than 4 speakers | none adequate; LS-EEND `.dihard3` (10 slots) or "unknown speaker" until offline pass | Needs real-audio validation |
| Post-meeting diarization / finalization (any length) | FluidAudio `OfflineDiarizerManager` (Community-1 VBx) | Remote track only in dual-track mode; reconcile with live labels by max overlap |
| Cross-session speaker identity (voice profiles) | FluidAudio centroids / `embedSpans` + `SpeakerManager`, own storage | Store model id with each profile; user-confirmed matching |
| Mic-track "You" detection (live) | FluidAudio Silero VAD streaming + AEC + voice-profile check | Time-overlap gating destroys real interruptions; AEC (Voice Processing I/O) needed |
| Fallback / A-B offline comparison | SpeakerKit via `DiarizationEngine` adapter | Offline only; over-segments; links WhisperKit |

## Sandbox/distribution flags

- Runtime model download from `huggingface.co` needs `com.apple.security.network.client`. Alternative: bundle models (offline diarizer 21 MB, LS-EEND 43 MB, VAD 1 MB, Sortformer about 240 MB per variant) and load locally; this removes the HF-availability dependency. FluidAudio's `loadFromHuggingFace` APIs take a `cacheDirectory`.
- Model caches must be redirected into the app container: `prepareModels(directory:)`, `LSEENDDiarizer.initialize(cacheDirectory:)`, `SortformerModels.loadFromHuggingFace(cacheDirectory:)`, `DiarizerModels.downloadIfNeeded(to:)`, `PyannoteConfig(downloadBase:)` and `VadManager(modelDirectory:)`. The `VadManager` default is `~/Library/Application Support/FluidAudio`, which a first PoC run wrote outside the allowed paths (that stray folder was deleted). Other defaults also use Application Support.
- Precompiled `.mlmodelc` is used so no Core ML compile-to-temp is needed.
- Mic capture: `NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input`. System-audio capture (ScreenCaptureKit or CoreAudio process tap) needs its own TCC permission. Not verified here (no real two-track capture run).
- Live diarization plus offline finalization means **recording meeting audio to disk** (per track) in the app container; that is sensitive data with consent, retention and deletion implications.
- Licences: third-party notices (Apache-2.0, MIT, CC-BY-4.0, possibly NVIDIA Open Model License for Sortformer v2.1) must appear in-app. The NVIDIA agreement has revocation on guardrail bypass, unilateral-update and indemnity clauses; avoid v2.1 unless legal signs off. Binary target `NemoTextProcessing` is downloaded at resolve time though not linked.
- Voice embeddings are biometric identifiers (GDPR Art. 9, Illinois BIPA, etc.). Store in the app container, encrypt at rest if feasible, never sync without opt-in, provide "delete voice profile".

## Open questions for the user

1. (Answered by coordinator: live labels are required in v1.) Is **provisional live labelling that changes at meeting end** acceptable UX, or must live labels never change (which would force Sortformer-style stability and no offline relabel)?
2. Typical meeting size: more than 4 remote speakers? Live labels cannot cover that with any engine tested (LS-EEND `.ami` and Sortformer cap at 4).
3. Should "You" be mic-track only, and are users typically on headphones? Without headphones we need AEC; do you accept shipping with Voice Processing I/O and a "You" voice-profile check?
4. Bundled models (offline, no `network.client` for models) vs first-launch download? Sortformer would add about 240 MB.
5. Voice profiles: opt-in per person? Retention and deletion? May other people's voices (remote participants) be stored at all, or only the user's own?
6. Licensing posture: CC-BY attribution acceptable? Is NVIDIA Open Model License (Sortformer v2.1) acceptable, or restrict to MIT/Apache/CC-BY models (then Sortformer v2 only, or skip Sortformer)?
7. May I get 2 to 3 of your own consented meeting recordings (ideally real mic + system-audio two-track captures) to validate LS-EEND `.ami` vs `.dihard3` vs Sortformer, calibrate the voice-match threshold, and test the dual-track AEC/gating? AMI headset audio overstates accuracy, and the dual-track result here is synthetic.
8. Is the recorded meeting audio allowed to be kept on disk until the offline finalization pass completes (needed for reconciliation), and for how long afterwards?
