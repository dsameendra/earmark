# Phase 0 benchmarks: ASR, Sinhala ASR, diarization (Apple M3 Pro, 18 GB)

Date: 2026-11-21. Author: Phase 0 benchmark agent. Nothing here is committed.
All numbers are measured unless a line says EXTRAPOLATION. Raw per-run values are in the tables; medians are over the listed runs.

## 1. Methodology

- Harness. `spikes/asr/Sources/asr-poc` got two new sub-commands for this work (`bench`, `benchapple`; the original `whisper`/`apple` commands are unchanged). `bench <audio> <model> <runs> [lang]` times model load and each full-file `WhisperKit.transcribe` call (word timestamps off, language forced to `en` unless stated, default decode options incl. temperature fallback) and reads `proc_pid_rusage` peak physical footprint. `benchapple` builds a fresh `SpeechTranscriber` + `SpeechAnalyzer` per run (asset already installed, no permission prompt needed) and times `analyzeSequence` + finalize. Diarization uses the existing `diar-poc` (`diarize fluid|speakerkit`, `stream <kind>`) wrapped in `/usr/bin/time -l`. Sinhala uses a copy of `spikes/sinhala/deferred_timing.py` with load time and 3 timed passes (scratchpad `sin_bench.py`, venv with `mlx-audio` and `torch`/`transformers`, both created outside the repo).
- Builds: Swift **release** (`swift build -c release`) for both PoCs. The earlier spike binaries were debug builds, so do not compare against any debug-build timing.
- Real-time factor (RTF) = wall seconds / audio seconds; "x realtime" = 1/RTF. Wall time is end-to-end for the call, not model-only.
- Runs: 3 or more per cell. Each WhisperKit process does a load then 2 or 3 transcribes; separate processes are used for load-time and cross-process repeatability. Spread is quoted as min-max.
- Memory: "peak footprint" is `ri_lifetime_max_phys_footprint` / `/usr/bin/time -l` "peak memory footprint" of the benchmark process. **This undercounts CoreML/ANE models**: WhisperKit turbo reports only about 200 to 250 MB although the model is 626 MB on disk, because ANE-compiled weights are mapped by system daemons (`ANECompilerService`/e5rt), and `SpeechAnalyzer` runs inside Apple's speech service (5 to 8 MB in our process). Real system-wide memory cost of CoreML/ANE models was NOT captured (no way to attribute it without sudo tooling); treat the numbers as "in-process only". MLX/PyTorch numbers are in-process and honest.
- Fixtures (from `fixtures/MANIFEST.md`): F1 `en-single-librispeech` 91.98 s; F3 AMI ES2004a 4-speaker window 240 s; F5b Wikimedia talk (H.264/AAC mp4) 283.4 s; AMI full meeting ES2004a Mix-Headset 1049.35 s for diarization; Sinhala SLR30 manifest: 40 clips, 4.5 to 9.2 s, 237.7 s total (`.model-cache/sinhala-eval/slr30_wav`).
- Models: WhisperKit CoreML `openai_whisper-large-v3-v20240930_626MB` (turbo class, downloaded for this run, 626 MB, within the <1 GB / <3 GB budget) and `openai_whisper-small_216MB` (already cached). Python Sinhala venv ~1.3 GB (in scratchpad, deletable); total new downloads about 2 GB.
- Cold vs warm load. True cold (page cache purged) needs sudo and was not done. "First ever" = first load after download, which includes CoreML/ANE specialization; "warm" = later process starts.

## 2. Machine state and honesty caveats (read this first)

| Item | Value |
|---|---|
| Hardware | Apple M3 Pro, 18 GB unified memory (`hw.memsize` 19,327,352,832), macOS 27.2.1 (Darwin 27.2.0) |
| Power | AC Power, battery 100% charged throughout (checked before every run via `pmset -g batt`) |
| Thermal | `pmset -g therm`: no thermal, performance or CPU-power warning level recorded at start or end. No `powermetrics` (needs sudo), so no sustained-clock data |
| Network | Only used for model/package downloads before the timed runs |
| Idle baseline | **The machine was NOT idle.** Before the first run: 5 user sessions, load average 4.7 / 4.9 / 7.7; the measured background was `bird`/`fileproviderd`/`cloudd` (iCloud), Clipen, Discord, Claude desktop, WindowServer. `top`: 17-21% user, 17-20% sys, 60-77% idle CPU; 15 GB of 18 GB "PhysMem used" (3.9 GB wired, 4.1 GB compressed), 2.4 GB unused; **swap 5.5 GB in use** (never changed during the runs, so no new paging was observed). Load average stayed 3.3 to 4.7 throughout. I did not close any of the user's apps, as instructed |
| Other activity | Other agent shells were editing docs (`fixtures/MANIFEST.md`, `specs/decisions`) during the run; text edits only, negligible CPU |

Consequences: (1) CPU-bound numbers (diarization CPU time, Python Sinhala) are probably slightly pessimistic; (2) ANE-bound WhisperKit numbers were very repeatable (spread under 2%), suggesting the ANE was effectively uncontended; (3) memory headroom on this machine was already poor, which is a mildly realistic stand-in for a user with a browser and Slack open. A re-run on a freshly rebooted machine would tighten the numbers but is unlikely to change conclusions.

## 3. ASR file transcription

### 3.1 Throughput

| Engine / model | Fixture (audio s) | Wall s, each run | Median wall s | RTF (median) | x realtime | Output words |
|---|---|---|---|---|---|---|
| WhisperKit turbo (large-v3-v20240930_626MB), lang=en | F1 (92.0) | 7.05, 6.99, 7.00, 7.02, 7.05, 7.05, 7.01, 7.01 (4 processes, 8 runs) | 7.03 | 0.076 | **13.1** (13.0-13.2) | 242 |
| same | F3 AMI 4-spk (240.0) | 16.22, 15.35, 15.07 | 15.35 | 0.064 | **15.6** (14.8-15.9) | 290, 295, 237 |
| same | F5b talk mp4 (283.4) | 17.01, 16.68, 16.75 | 16.75 | 0.059 | **16.9** (16.7-17.0) | 626 |
| WhisperKit small (216MB), lang=en | F1 (92.0) | 5.65, 5.58, 5.56, 5.51, 5.56, 5.55 (3 processes, 6 runs) | 5.56 | 0.060 | **16.5** (16.3-16.7) | 242 |
| same | F3 (240.0) | 9.67, 14.29, 9.35 | 9.67 | 0.040 | 24.8 (16.8-25.7) | 246, 313, 301 |
| Apple SpeechAnalyzer (`SpeechTranscriber`, en-US, on-device) | F1 (92.0) | 1.79, 1.57, 1.66 | 1.66 | 0.018 | **55** (51-59) | 242 |
| same | F3 (240.0) | 1.79, 1.83, 1.74 | 1.79 | 0.0075 | **134** (131-138) | 299 |
| same | F5b (283.4) | 3.98, 3.96, 3.78 | 3.96 | 0.014 | **71.5** (71-75) | 623 |

Notes.
- Word counts for WhisperKit on F3 differ run to run (237 to 295; small 246 to 313) while F1 and F5b are stable. This is the default decoder's temperature fallback on a noisy multi-speaker meeting, and it also explains the small-model wall-time spread (14.3 s outlier). Do not read the F3 small-vs-turbo ordering as "small is faster": the work done differs. Use F1/F5b for the speed comparison: small is about 1.25x faster than turbo, which is not much, because the ANE decoder is bounded by per-token overhead rather than parameter count at this size.
- Apple counts are close to the Whisper counts on F1 (242 = 242) and F5b (623 vs 626); accuracy was not scored here (see `asr-engines.md`). On F3, Apple's 299 words is in the same range as Whisper's fallback-dependent 237 to 313.
- Apple's file path is 4 to 8 times faster than WhisperKit turbo on identical audio. Its process footprint is 5 to 8 MB because inference runs out of process; the system-side memory was not measured.
- Mixed-language/auto-detect: WhisperKit turbo with language detection on a 10 s clip costs about 1.2 s vs 1.15 s forced (negligible).

### 3.2 Model load

| Model | First ever load (download + specialization) | Subsequent process loads (s) | Median warm |
|---|---|---|---|
| turbo 626MB | 115.5 s (includes the 626 MB download, not separable; ran while a stray filesystem scan was also active) | 4.01 (first load after compile), 1.05, 1.00, 1.04, 1.17, 1.15 | **1.1 s** |
| small 216MB | 22.4 s (one occurrence in a later process, after other models had been used; looks like ANE cache re-specialization) | 0.58, 0.59, 0.61 | **0.6 s** |
| Qwen3-ASR 0.6B 8-bit (MLX, Python) | not measured (files already local) | 2.41 | 2.4 s |
| whisper-small-sinhala (PyTorch MPS fp16) | not measured | 12.59 | 12.6 s |
| Apple SpeechAnalyzer | n/a (assets pre-installed); per-run setup under 10 ms | | |

Implication: a 20 to 120 s cost exists the first time a model runs on a machine and can recur after the OS evicts the ANE cache. The app needs a "preparing model" state and should warm-load the model on launch or before recording starts, not on the first Record press.

### 3.3 Live-partial proxy (latency of one decode of a window)

A true live pipeline was not run (it needs the microphone). As a proxy I timed one full `transcribe` call on N-second clips cut from F1, 5 runs each, median:

| Window | turbo 626MB | small 216MB |
|---|---|---|
| 3 s | 0.74 s | 0.27 s |
| 5 s | 0.87 s | 0.45 s |
| 10 s | 1.15 s | 0.70 s |
| 30 s | 2.70 s | 1.90 s |

There is a fixed overhead of about 0.6 s for turbo (30 s padded encoder pass) and about 0.2 s for small. **Verdict against the "live partial under 1.5 s" target: met on M3 Pro for turbo up to about 10 to 12 s decode windows and for small up to about 20 s.** This is decode latency only; end-to-end partial latency adds the audio buffering/VAD chunk and any streaming-policy delay. Apple SpeechAnalyzer's volatile-result latency was not measured (needs live audio input path; the file path only proves throughput).

### 3.4 Memory (process-level)

| Engine | Peak footprint (3 runs) | Comment |
|---|---|---|
| WhisperKit turbo 626MB | 192, 192, 190 MB (2 x F1); 209 MB (F3); 238 MB (F5b) | undercounts ANE-resident weights, see methodology |
| WhisperKit small | 197 to 222 MB | same |
| Apple SpeechAnalyzer | 5 to 8 MB in our process | out-of-process |

## 4. Sinhala ASR (spikes/sinhala, Python; not shippable as is)

Model files local; 40 clips, 237.7 s, greedy, `max_tokens = 64 + 30*dur`. One warm-up clip discarded, then 3 full passes.

| Engine | Load | Per-pass wall s | RTF each pass | RTF median | x realtime | Clip latency median / p90 | Peak footprint |
|---|---|---|---|---|---|---|---|
| Qwen3-ASR-0.6B-Sinhala 8-bit, Python mlx-audio 0.32.4 (MLX 0.32.4) | 2.4 s | 27.6, 30.7, 28.2 | 0.116, 0.129, 0.119 | **0.119** | **8.4** (7.8-8.6) | 0.65-0.73 s / 0.91-1.04 s | 2.28 GB (RSS 970 MB) |
| SinhaSpeech whisper-small-sinhala-run12-best, PyTorch MPS fp16 | 12.6 s | 24.5, 21.0, 21.1 | 0.103, 0.088, 0.089 | **0.089** | **11.3** (9.7-11.3) | 0.51-0.58 s / 0.63-0.76 s | 2.27 GB (RSS 1.8 GB) |

Notes: clips are short (4.5 to 9.2 s), so a fixed per-clip overhead is included; long-form chunked throughput was not measured. Qwen is slightly below the 10x file-transcription target on this machine with this Python path; the Whisper-small fine-tune is just above. Accuracy is the other axis (see `sinhala-asr.md`; Qwen CER 6.2% on SLR30 in that spike). Both numbers are a Python reference only: shipping needs Swift (mlx-audio-swift is what the Qwen card was validated with) or a CoreML conversion (`spikes/sinhala/convert_finetune_coreml.md`), and ~2.3 GB peak is large for the 8 GB tier.

## 5. Diarization

AMI ES2004a Mix-Headset, 1049.35 s (4 speakers), `.model-cache` models, release build, 3 runs. Each run is a fresh process so wall time includes model load.

### 5.1 Offline

| Engine | Wall s (runs) | Median | x realtime | CPU time (user+sys) | Peak footprint | Output |
|---|---|---|---|---|---|---|
| FluidAudio offline (VBx) | 5.06, 3.84, 3.98 | 3.98 | **264** | about 5.4 s | 902, 909 (median), 928 MB | 114 turns, 4 spk |
| SpeakerKit | 14.85, 9.41, 10.38 | 10.38 | **101** | about 15.2 s | 671, 686, 715 MB | 156 turns, 5 spk (over-segments, as in `diarization.md`) |

### 5.2 Streaming (chunks fed as fast as possible, as in `run_stream_matrix.sh`)

| Engine | Wall s (runs) | Median | x realtime | CPU time per 1049 s of audio | CPU as share of one core at real-time pacing | Peak footprint | Output |
|---|---|---|---|---|---|---|---|
| LS-EEND `.ami` (100 ms step) | 11.70, 11.99, 11.91 | 11.91 | **88** | 12.0 s | about 1.1% (plus ANE/GPU) | 138 MB | 246 turns, 10,485 updates |
| Sortformer v2 `fastV2` | 48.86, 43.75, 41.55 | 43.75 | **24** | 13.1-14.1 s (3.2 s sys) | about 1.3% | 203, 213, 213 MB | 481 turns, 2,185 updates |
| Sortformer v2 `balancedV2` | 138.36, 130.26, 130.67 | 130.67 | **8.0** | 7.0 s | about 0.7% | 180, 194, 194 MB | 483 turns |

All three keep up with live audio by a wide margin (minimum 8x). The CPU-share column is total CPU seconds divided by audio seconds, i.e. what the process would consume pacing at 1x; model compute on the ANE/GPU is not included. `balancedV2` is slow in wall time while using little CPU, which suggests it is waiting on the ANE/GPU or Core ML dispatch, not CPU-bound.

### 5.3 Concurrency (the one parallel test; 3 repetitions)

WhisperKit turbo on F5b (2 runs per process) **at the same time as** LS-EEND streaming ES2004a:

| Metric | Alone | Concurrent |
|---|---|---|
| Turbo x realtime | 16.7 to 17.0 | 16.3 to 17.0 (run 1 of each pair 16.3-16.5, run 2 17.0) |
| LS-EEND wall s | 11.70 to 11.99 | 13.48, 13.56, 13.97 (+13 to +17%) |

Running transcription and LS-EEND diarization together on the 18 GB tier costs essentially nothing for ASR and about 15% for diarization. In real time both stay far above 1x. (Real-time audio capture and UI were not part of this test.)

## 6. Comparison to product targets

| Target | Result on M3 Pro 18 GB | Status |
|---|---|---|
| File transcription at least 10x realtime with a turbo-class model on an M1 Pro class machine | WhisperKit turbo 626MB: 13.1 to 16.9x (language forced); small: 16.5x; Apple SpeechAnalyzer: 55 to 134x | Met with margin **on M3 Pro**. M1 Pro: see extrapolation |
| Live partial under 1.5 s with WhisperKit | 0.74 s (3 s window) to 1.15 s (10 s window) turbo decode latency; 0.27 to 0.70 s small | Met for windows up to about 10 to 12 s on M3 Pro (decode only, not end-to-end) |
| Sinhala file transcription | 8.4x Qwen, 11.3x whisper-small-si (Python reference) | Borderline (Qwen), Python only |
| Diarization keeps up with live | 8x to 88x streaming; offline 101x to 264x | Met with margin |

### Extrapolation to M1 Pro and M1 8 GB (NOT measured; labelled estimate)

- Basis: WhisperKit on Apple Silicon is dominated by the Neural Engine encoder plus per-token decoder dispatch, and our measurement shows no dependence on background CPU load. The M3-generation ANE is faster than M1's (my recollection of Apple's published peak figures is roughly 18 vs 11 TOPS; not verified here), and the M3 Pro's memory bandwidth (150 GB/s) is below the M1 Pro's 200 GB/s but bandwidth is not the limit for these models. A reasonable planning assumption is **1.3 to 2x slower than the M3 Pro**.
- **M1 Pro (16 GB class)**: turbo file transcription about 7 to 12x realtime, i.e. **around the 10x target, not safely above it**; small about 9 to 13x. Live partials with turbo: about 1.0 to 1.5 s on 3 to 10 s windows, so the 1.5 s target is at risk above about 8 s windows; use small or shorter windows on that tier. Apple SpeechAnalyzer would stay far above 10x (est. 25 to 90x).
- **M1 8 GB**: same ANE as M1 Pro, so similar speed to the line above (about 6 to 10x turbo). The risk is memory, not speed: macOS plus a browser typically leaves about 3 to 4 GB; turbo's 626 MB CoreML bundle (plus ANE-side copies) fits alone, but our own machine already swaps at 5.5 GB with 15 of 18 GB used. The Sinhala Python path (2.3 GB) would not be viable beside an ASR model on 8 GB. Expect page-ins during first load (the 22 s/115 s specialization cost could be higher on 8 GB).
- These estimates should be replaced by a real run on an M1-class device before the tier thresholds are finalised.

## 7. Conclusions

1. WhisperKit turbo-class (626 MB) transcribes files at 13 to 17x realtime on M3 Pro with very stable timing (spread under 2%); small is only about 1.25x faster. The small/turbo speed gap is too narrow to justify shipping small as the default on any tier that can hold turbo; its value is memory and live latency.
2. Apple SpeechAnalyzer is 4 to 8x faster than WhisperKit turbo for the file path, near-zero in-process memory and zero model management, with comparable word counts on our English fixtures. For English file transcription it should be the speed baseline; WhisperKit is the language-coverage and word-timestamp/control option. (Accuracy comparison lives in `asr-engines.md`.)
3. Diarization is cheap. LS-EEND streams at 88x realtime with 138 MB and about 1% of a core; offline FluidAudio finalizes a 17.5 minute meeting in about 4 s. Sortformer `balancedV2` is 11x slower than LS-EEND in wall time; accuracy trade-offs are in `diarization.md`.
4. ASR and diarization overlap with almost no penalty on this machine (section 5.3), so a "one heavy model resident" policy is not needed for speed on 18 GB-class hardware; it matters for memory on the 8 GB tier.
5. Sinhala via Python is workable for evaluation (8 to 11x) but ~2.3 GB peak and a Python runtime are not distributable; a Swift/CoreML port is required before it can be a product feature.
6. Cold start is the user-visible hazard: 22 to 115 s of CoreML specialization at first use, and again whenever the ANE cache is evicted.

## 8. Hardware-tier recommendations

These are recommendations from the M3 Pro data plus the EXTRAPOLATION above, not measurements on those tiers.

| Tier | Typical machine | Default ASR | Optional | Diarization | Concurrency / residency policy |
|---|---|---|---|---|---|
| tier8 (8 GB) | M1/M2 8 GB | Apple SpeechAnalyzer for supported locales; WhisperKit small (216 MB) as fallback/long tail | turbo 626MB only on explicit opt-in, loaded on demand | LS-EEND live (138 MB) + offline FluidAudio at meeting end (about 0.9 GB peak, short-lived) | **One heavy model resident.** Unload ASR before the offline diarization pass, or run them strictly sequentially. No Sinhala Python-class model alongside anything else. Sinhala (about 2.3 GB) only as an exclusive "Sinhala mode" |
| tier16 (16 to 18 GB) | M1 Pro/M2 Pro/M3 Pro | WhisperKit turbo 626MB (default for non-Apple-supported languages), Apple SpeechAnalyzer for English fast path | small as a low-latency live engine | LS-EEND live + FluidAudio offline | Measured: ASR and diarization concurrently cost about +15% on diarization only. Policy "one heavy model resident" is **not required** for compute, but keep it for the Sinhala model (2.3 GB) and for any LLM translation model |
| tier32 (32 GB+) | Pro/Max/Ultra | turbo (and larger WhisperKit variants if added later; not measured) | multiple engines at once (live small + final turbo; Sinhala + English) | any (Sortformer fallback fine) | Residency policy can be relaxed: keep live engine + final-pass engine + diarizer + a translation model loaded. Not measured: translation model memory/speed (see `translation.md`) |

The "one heavy model resident" policy remains valid and cheap to implement, but its justification is memory on tier8 and the Sinhala/translation models, not CPU/ANE contention.

## 9. Optimisation suggestions

- Warm-load at app launch (or on opening a meeting) and show a "preparing" state; surface the first-use download+specialization (22 to 115 s) in onboarding, not on first record.
- Pin language when known: auto-detect adds about 0.05 s on a 10 s window, but the bigger benefit is avoiding fallback/hallucination variance seen on F3 (word count spread 237 to 295).
- Reduce decode variance on meetings: cap temperature-fallback retries or use VAD-segmented windows for live; wall time on F3 for small spiked 48% on one run.
- Use Apple SpeechAnalyzer for English/other supported locales as the default fast path and keep WhisperKit as the language-coverage engine; this also removes about 0.6 to 1.0 GB of model download for most users.
- Live partials: decode on VAD-bounded windows of 3 to 8 s with turbo (0.74 to 1.0 s) or small (0.27 to 0.6 s); revisit window growth once end-to-end timing is measured.
- Diarization: stream LS-EEND live (1% CPU), run FluidAudio offline once at meeting end (4 s per 17 minutes); avoid SpeakerKit (slower, 5 clusters for 4 speakers) and Sortformer `balancedV2` (130 s for 1049 s).
- Sinhala: port Qwen3-ASR to Swift MLX or convert to CoreML; investigate 4-bit; chunk to 20 to 30 s with VAD; do not hold it resident on 8 GB.
- Add a `--bench` mode to the future app (load time, RTF, peak footprint, thermal state) so tier thresholds can be validated on user hardware, including M1/8 GB.

## 10. Limitations

- Machine not idle (section 2); all 3-run spreads are small, but absolute numbers may shift on a quiet machine.
- No true cold-cache loads (needs sudo purge); no real mic/live pipeline; no Apple SpeechAnalyzer live latency; no WER scoring in this task (speed only; word counts quoted are a sanity check, not accuracy).
- ANE-side memory of CoreML models is not captured (section 1).
- No M1-class hardware was available; section 6 numbers are estimates.
- Translation models (MADLAD/NLLB/MLX LLM) were not benchmarked: they need large downloads (multi-GB, over the budget) and a Python/GGUF toolchain; see `spikes/translation/scripts` and `translation.md`.
- Sinhala runs are the Python reference implementation on 4.5 to 9.2 s clips only.

## 11. Recommendation

1. Treat the 10x file-transcription target as **met on M3 Pro (13 to 17x turbo; 55 to 134x Apple)** and **unproven on M1 Pro**: estimate is about 7 to 12x for turbo. Get one real M1 Pro and one M1 8 GB run before locking tier thresholds.
2. Default engine plan: Apple SpeechAnalyzer where the locale is supported (fast path, no model memory), WhisperKit turbo 626MB for everything else on tier16/tier32, WhisperKit small on tier8. Keep WhisperKit small for live partials on all tiers (0.3 to 0.7 s window latency).
3. Diarization: FluidAudio LS-EEND live plus FluidAudio offline at the end; drop SpeakerKit and keep Sortformer only as a fallback.
4. Keep the "one heavy model resident" policy as an 8 GB-tier and Sinhala/translation-model rule, not as a general rule.
5. Sinhala: budget a Swift/CoreML port in a later phase; Python reference results are only for model selection.
6. Build model warm-up and first-run specialization UX in from the start.

## 12. Sandbox/distribution flags

- WhisperKit model download goes to a user-chosen `downloadBase` and uses `huggingface.co`: needs `com.apple.security.network.client`, or bundle/pre-stage models. `WhisperKitConfig` here used `EARMARK_MODEL_CACHE`; in the app redirect into the container (Application Support in the sandbox container, not the default Documents path). The first download wrote to `<base>/models/argmaxinc/...` (an extra `models/` level), so verify the final path layout.
- Models are 216 MB to 626 MB (WhisperKit), 43 MB to 240 MB (diarizers), about 21 MB offline diarizer, ~1 GB (Qwen Sinhala MLX), and the first CoreML specialization is long: decide between bundling (huge app, notarization/upload size) vs. first-launch download.
- Apple SpeechAnalyzer: asset install via `AssetInventory` is system-managed; the file-analysis path ran without any permission prompt from a command-line binary. The packaged/sandboxed app may still need `NSSpeechRecognitionUsageDescription` for related Speech APIs; verify in the signed build (not tested here). The SpeechAnalyzer path requires macOS 26+ (`platforms: .macOS(.v26)` in this spike).
- CoreML/ANE: no extra entitlement needed, but memory is attributed to system daemons, so Activity Monitor will not show the real cost; sandbox does not change that.
- Python/MLX route used in section 4 is not shippable inside the sandbox (no interpreter, JIT); needs Swift MLX or CoreML.
- No microphone/ScreenCaptureKit/system-audio permission was exercised in this task.

## 13. Open questions for the user

1. Can I get access to an M1-class Mac (ideally 8 GB) or should tier thresholds be set from the extrapolation? What is the minimum supported machine for v1?
2. Is Apple SpeechAnalyzer acceptable as the default English engine (macOS 26+ only, Apple-controlled model, no custom vocabulary tuning here), or must the app ship with WhisperKit as the single default for consistency and cross-version behaviour?
3. First-launch download of 0.2 to 0.6 GB (plus a 20 to 120 s specialization) vs bundled models: which does the product want?
4. Should Sinhala ship in v1 at the cost of a 2.3 GB engine (exclusive mode on tier8, needs a Swift port), or be a later add-on?
5. Is a quiet-machine re-run (reboot, no background apps) required for the spec, or are these numbers, taken on a loaded 18 GB machine, acceptable as the baseline?
6. Is the less-than-1.5 s live-partial target to be measured end-to-end (needs a mic session you can run with permissions), and with which engine: WhisperKit small/turbo or SpeechAnalyzer volatile results?
