# Sinhala ASR quality spike (Phase 0)

Author: Phase 0 research agent. Date: 2026-11-21 (all "accessed" dates are this date).
Machine: Apple M3 Pro, 18 GB, macOS 27.2.1, Xcode 27.2. **No timing benchmarks were run** (shared machine); speed scripts are deferred (`spikes/sinhala/deferred_timing.py`).
Scripts and numbers: `spikes/sinhala/` (`results_summary.json` holds scored numbers; no transcripts or audio are committed or stored in the repo).

## TL;DR

1. Stock Whisper (large-v3-turbo measured here) is **unusable for Sinhala**: 105-146% CER on read speech, 94-168% on conversation, hallucinated loops and wrong-script output.
2. A public, licensed, mixed Sinhala+English test set **does not exist**. FLEURS has no Sinhala; Common Voice Sinhala is a handful of clips. The only code-mixed audio is `SPEAK-ASR/youtube-sinhala-asr`, which has **no licence** (internal evaluation only).
3. Best candidate for the app: **`Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit`** (MLX, 1.0 GB, code-switching aware, CC BY-SA 4.0). It is the only candidate with evidence of working on held-out conversational/code-mixed speech (author: 20.5% CER; our independent 60-clip re-measure: 21.5% CER), and the Python mlx-audio path reproduced the author's Swift numbers, which the author never tested. It needs MLX as a second runtime next to WhisperKit.
4. Best Whisper-family fallback that fits the WhisperKit/CoreML architecture: **`SinhaSpeech/whisper-small-sinhala-run12-best`** (244M, Apache-2.0 declared): 5.5% CER on clean read speech (n=40). Its conversation score here (4.7% CER) is **contaminated and must not be trusted**. No CoreML build exists; conversion is documented but could not be executed on this machine (needs Python 3.11).
5. Primary gap: we have no clean real-world Sinhala+English recordings. We need ~20 min from the user (list in the last section).

## 1. Public Sinhala test data (verified)

| Corpus | Content | Licence | Verdict |
|---|---|---|---|
| FLEURS `google/fleurs` (sha 70bb2e84, 2026-05-15) | 102 languages | CC-BY-4.0 | **No Sinhala.** The repo file list has no `si_*` entry (the only `s*` locales are `sd_in`, `sn_zw`, ...). |
| Common Voice (now only via Mozilla Data Collective, since Oct 2025) | Sinhala: "Spontaneous Speech 3.0" 21 clips / 0.12 h / 1 speaker; scripted-set size not confirmed | CC0-1.0 | Too small. https://datacollective.mozillafoundation.org/datasets/cmmysetwg00fkmf07v0akjit6 |
| OpenSLR 52 | ~185K read utterances (185,293 rows in `utt_spk_text.tsv`), 478 speakers (per Nerdstorm card), crowd-sourced by Google | CC BY-SA 4.0 | The training set of essentially every public Sinhala fine-tune. 71% of a speaker-disjoint test split reads sentences that also occur in training (Nerdstorm card), so any SLR52 number flatters fine-tunes. https://www.openslr.org/52/ |
| OpenSLR 30 | 1,251 utterances, 12 speakers, Google TTS corpus, 699 MB | CC BY-SA 4.0 | Not in any candidate's stated training data. 148 of 1,251 texts (12%) also occur verbatim in SLR52, so those were excluded (1,103 clean refs). **Used here as the clean read-speech set.** https://www.openslr.org/30/ |
| `SPEAK-ASR/youtube-sinhala-asr` (sha 4203ccbc, 2026-02-23) | 4,037 clips, 9.1 h, 111 videos, 34 channels, flags `is_code_mixed` (54%), `has_noise`, `uploader` | **None** (author of the Nerdstorm card: "published without a licence and used with its authors' permission"; recordings belong to the channels) | Only public conversational/code-mixed set. Its own splits put clips of the same video in train and test (58 of 111 videos, per Nerdstorm card). **Internal evaluation only; never ship or redistribute.** |
| `SinhaSpeech/sinhala-asr-data` (sha 371180db) | 154,828 clips: ~97% OpenSLR52, ~2% YouTube, 0.6% BizBrains, 0.6% Linga | `unknown` | Provenance unclear. Not used. |

Mixed English+Sinhala audio is scarce. The only conversational code-mixed data found is the unlicensed SPEAK-ASR set (BizBrains and Linga appear only inside the SinhaSpeech aggregate, with no separate public release found).

## 2. Candidates

All HF facts fetched via the HF API / model cards on 2026-11-21.

| Model | Params / size | Licence (declared) | Training data | Self-reported quality | Runtime / format |
|---|---|---|---|---|---|
| `openai/whisper-large-v3-turbo` (sha 41f01f3f) | 809M, 1.6 GB | MIT | multilingual weak supervision; "si" is a valid language token | none for Sinhala | WhisperKit CoreML exists (`argmaxinc/whisperkit-coreml`: `openai_whisper-large-v3-v20240930_turbo*`, MIT) |
| `openai/whisper-large-v3` (sha 06f233fe) | 1.55B, 3.1 GB | Apache-2.0 | same | none | WhisperKit CoreML exists. Not downloaded (budget); a third-party measurement and our turbo run indicate the same failure |
| `SinhaSpeech/whisper-small-sinhala-run12-best` (sha 96eac628, 2026-10-21) | 244M, ~1 GB fp32 | Apache-2.0 | `SinhaSpeech/sinhala-asr-data-v6`: 123K train utts, ~97% OpenSLR52 + ~2% YouTube + small private sources | 15.52% WER / 4.36% CER on its own speaker-disjoint test (15,860 utts, mostly OpenSLR52) | HF safetensors; card says CTranslate2 conversion exists for the project's live captioning. No CoreML |
| `SPEAK-ASR/whisper-si-exp-10-medium-all` (sha a4ed7bc6, 2026-03-19) | LoRA on whisper-medium (769M base) | Apache-2.0 | OpenSLR52 (noise-removed, normalised) + SPEAK YouTube | 10.85% WER on a mix of the two evaluation sets | LoRA adapter only; must be merged before conversion. Not run here (base is another 3 GB) |
| `SPEAK-ASR/whisper-si-exp-10-medium` (sha 7b6ad63e) | same, OpenSLR52 only | Apache-2.0 | OpenSLR52 | 9.99% WER (SLR52 test) | same |
| `kasunw/whisper-large-v3-sinhala` (sha f66f6f53, 2026-09-15) | 1.55B, ~6 GB fp32 shards | Apache-2.0 | OpenSLR52 | none stated | Not downloaded (budget) |
| `Lingalingeswaran/whisper-small-sinhala`, `seniruk/whisper-small-si`, `janiduchamika/whisper-small-sinhala-general-185k`, many `RRashmini/*` | small | Apache-2.0 | OpenSLR52-derived / unknown | mostly none | Not evaluated (same class as run12) |
| `Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit` (sha 047217cb, 2026-09-28, second revision) | ~0.6B, 8-bit MLX, 1.0 GB | **CC BY-SA 4.0** (derived from OpenSLR52; base Qwen3-ASR-0.6B is Apache-2.0) | OpenSLR52 (442 speakers) + 7.4 h conversational SPEAK YouTube (25 channels, 54% code-mixed) + 2,500 replay clips for other languages | Author's held-out test: 6.86% CER (read, new sentences), 20.46% CER / 41.5% WER (conversation, 5 unseen channels, 566 clips), 24.35% CER on the code-mixed subset | MLX only (mlx-audio-swift >= 01dec7c). Qwen3-ASR itself covers 30 languages incl. English/Chinese |
| Omnilingual ASR CTC 300M/1B (Meta) | 0.3-1B | Apache-2.0 (per third-party blog; GitHub API shows NOASSERTION, not independently verified) | 1600+ languages | Third-party measurement (blog, 292 SLR52 clips, though SLR52 is in its training data): CER 64-76%, 30-32% with script forcing | Not recommended |
| Meta MMS | - | Non-commercial (per blog) | - | - | Excluded by licence |
| `mjwong/...-singlish` | - | - | Singapore English (not Sinhala) | - | Excluded: name collision only |

Third-party measurement used as context: Purinda's blog series (https://purinda.com/posts/sinhala-asr-1-measuring/, fetched 2026-11-21) measured Whisper large-v3-turbo forced to Sinhala at 584% CER / 736% WER on SLR52 clips, plus Omnilingual numbers above. This agrees in direction with our own measurement (below).

## 3. Measurements

### Method (honest summary)
- Same scorer for all models (`spikes/sinhala/sinmetrics.py`): Unicode NFC, strip U+200D/U+200C (also reported with them kept), lowercase, drop punctuation/symbols (Unicode categories P*/S*), collapse whitespace. **CER (spaces removed) is the headline**; WER is inflated by inconsistent word spacing in references (observed in the SinhaSpeech and Nerdstorm cards) and is shown for completeness.
- "raw" = all output kept. "cut" = repetition loops truncated where they begin (mimics a loop guard). Decoding: greedy, `max_new_tokens`/`max_tokens` = 64 + 30 s of audio (Whisper capped at 440). Whisper forced to `language=sinhala, task=transcribe`; Qwen given no language (as in the author's test). Whisper models ran on CPU fp32, Qwen via Python `mlx-audio` 0.6.7 on MLX; transformers 5.24, torch 2.15, Python 3.14 venvs in the scratchpad.
- **Set A, clean read speech:** OpenSLR 30 (CC BY-SA 4.0), 40 utterances across 12 speakers, random after excluding any text present in SLR52 (`prep_slr30_eval.py` streamed the tarball and stopped early). Total audio about 3 min. n=40.
- **Set B, conversation + code-mixed:** `SPEAK-ASR/youtube-sinhala-asr`, restricted to the **5 channels the Qwen model's author held out of training** (Carnage, Newsfirst Sri Lanka, Arogya, Anoma's Kitchen, Hera's Diary), 2-20 s clips, 30 code-mixed + 30 Sinhala-only (random, seed 0), pulled across all three SPEAK splits. n=60. Internal evaluation only.
- These are **small samples**. Uncertainty was not computed (no bootstrap); as a rule of thumb, treat differences below ~1-2 CER points (set A) and ~4-5 points (set B) as noise. Do not rank models separated by less than that.
- No speed was measured.

### Results (CER %, corpus-level; n = clips)

| Model | Set A: SLR30 read (n=40) | Set B: all (n=60) | Set B: Sinhala-only (n=30) | Set B: code-mixed (n=30) |
|---|---|---|---|---|
| Qwen3-ASR-0.6B Sinhala 8-bit (Python mlx-audio) | 6.20 (WER 34.6) | **21.49** (WER 43.3) | 14.83 | 27.48 |
| Whisper-small run12 (SinhaSpeech) | **5.51** (WER 32.5) | 4.73 (WER 14.8) **contaminated, see below** | 4.09 | 5.31 |
| Whisper large-v3-turbo (stock) | 145.9 raw / 104.8 cut (22/40 loops) | 167.6 raw / 94.2 cut (53/60 loops) | 181.8 / 97.3 | 154.7 / 91.3 |

Keeping ZWJ changes CER by at most 0.3 points everywhere (Qwen set B 21.65 vs 21.49; run12 4.77 vs 4.73), so ZWJ handling is not driving any conclusion.

Script/English handling (share of Latin letters among alphabetic characters, set B code-mixed): reference 39.3%, Qwen 29.8%, run12 37.5% (contaminated), turbo 9.6%. Qwen writes about three quarters of the English the references write in Latin letters and transliterates the rest into Sinhala script; part of its code-mixed CER is a convention mismatch (Sinhala-script rendering of an English word counts as errors) rather than mishearing.

### Validity checks
- **Qwen via Python mlx-audio reproduces the author's Swift results**: author 20.46% CER on its 566-clip held-out conversation test (24.35% on code-mixed, 14.55% Sinhala-only); ours 21.49% / 27.48% / 14.83% on a 60-clip subset. The model card warned the Python path was untested and that feature extraction matters; the agreement says it works well enough for evaluation. Read speech: author 6.86% on SLR52 new-sentence clips; ours 6.20% on SLR30.
- **run12's 4.7% on set B must not be believed.** It is 4x better than the only model whose training data is known to exclude these channels, with near-perfect handling of English words. `SinhaSpeech/sinhala-asr-data` contains ~2% YouTube material (consistent with a copy of the SPEAK-ASR YouTube data) split randomly, not by channel. I could not verify clip-level overlap (the HF parquet text-column read of the 12 GB train file timed out; `check_contamination.py` is provided to retry). Treat run12's conversational ability as **unmeasured**.
- Its 5.51% on set A is a valid out-of-corpus read-speech number (SLR30 not in its training list), but read-speech only; Qwen (6.2%) and run12 (5.5%) are statistically indistinguishable at n=40.
- Stock turbo: the 584% CER in the blog and our 105-146% are different metrics/settings (we capped tokens and cut loops) but agree: unusable. Failure modes seen: character-repetition loops, Devanagari/Gujarati/Gurmukhi script output, no Sinhala.
- `openai/whisper-large-v3` (non-turbo) and the SPEAK medium LoRA were not run (download budget). No evidence suggests the former behaves better; the latter is documented only by its card (10.85% WER, contaminated by shared-video splits).

## 4. CoreML / WhisperKit path for fine-tunes

Verified facts (2026-11-21):
- WhisperKit (argmaxinc, MIT) latest release v1.1.1 (2026-10-08). `Models.swift` maps "sinhala"/"sinhalese" to code `si`, so language forcing works.
- `argmaxinc/whisperkit-coreml` (MIT, sha 0f63a780, 2026-08-19) hosts stock tiny/base/small/medium/large-v2/v3/v3-turbo variants (including 216 MB small, 547-954 MB quantised large variants). **No Sinhala fine-tune in CoreML exists** (HF searches for "sinhala coreml" and "whisperkit sinhala" returned nothing).
- whisperkittools (MIT, last commit 2026-02-19; no GitHub releases): `whisperkit-generate-model --model-version <hf repo/dir> --output-dir out`. The README does not discuss fine-tunes or LoRA. `setup.py` pins `torch==2.5.0`, `transformers==4.53`, `numpy<2.4.0`; README example uses Python 3.11; Xcode required.
- **Not executed here**: torch 2.5.0 has no wheels for the Python 3.14/3.15 on this machine, and installing 3.11 is outside the allowed write paths. Steps and risks are in `spikes/sinhala/convert_finetune_coreml.md`.

Risks: converting a fine-tune is untested territory for this toolchain (tokenizer/added tokens, generation-config forcing, quantisation drift); LoRA adapters need a PEFT merge first; the resulting CoreML model must be re-scored against the PyTorch numbers above before adoption; Whisper's tokenizer is not Sinhala-optimised (observed: stock turbo loops to the token cap), so long outputs may be slow and loop-prone; Whisper-family models have no built-in code-switching handling and 30 s window constraints.

Alternative runtime path: MLX in-process (Qwen3-ASR). The author reports ~256 ms median for a 4.4 s clip on M4 Pro (their number, not ours), mlx-audio-swift (MIT, pushed 2026-11-20) is the supported Swift runtime, and a loop guard keyed to clip length is required (author recommends `maxTokens = 64 + 30*seconds`; the library's own loop backstop only catches loops of <= 3 distinct tokens).

## 5. Sinhala script rendering in transcripts

- macOS ships **Sinhala MN** and **Sinhala Sangam MN** (font files `Sinhala MN.ttc` and `Sinhala Sangam MN.ttc` found under `/System/Library/Fonts`). CoreText font cascading picks Sinhala Sangam MN for Sinhala text under a Latin system font (checked with `CTFontCreateForString` on this machine). SwiftUI `Text` / AppKit text use CoreText, so conjunct shaping (rakaransaya, yansaya, repaya), pre-base vowel signs (e.g. U+0DD9), and ZWJ-controlled conjuncts render correctly without extra work.
- **Normalisation:** model output and references disagree on ZWJ (U+200D) and conjunct spelling; store transcripts as NFC, **do not strip ZWJ** in the stored text (it changes the glyph), strip only for search/matching and evaluation.
- **Line breaking:** Sinhala uses spaces between words; ICU/CoreText line breaking is OK, but break opportunities inside long unspaced model output are poor, and models often glue or split compounds ("කළහැකි" / "කළ හැකි"). Do not hard-wrap in storage; let the text view wrap.
- **Font metrics:** Sinhala glyphs have tall ascenders/descenders; use generous line height (about 1.4-1.5x) or lines clip in custom layouts; Latin words in mixed text fall back font-by-font, so mixed lines can have uneven baselines.
- **Export (SRT/Markdown/PDF):** write UTF-8 NFC; PDF export must embed the fallback font; test with a conjunct-heavy sample ("ශ්‍රී ලංකා", "ක්‍රියාත්මක").
- **Mixed script:** English words in code-switching come out as Latin letters (about 3/5 to 5/6 of cases for Qwen per its card, about 76% of the reference Latin share in our measure); UI should not assume a single script per segment.

## Recommendation

1. **Default Sinhala model: `Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit` (rev 047217cb)**, run in-process via mlx-audio-swift (MIT), with: language auto-detect, `maxTokens = 64 + 30*duration`, a repetition-loop guard (one runaway in 566 clips even with the guard; 7 for the first revision), and a "Sinhala quality: preview" label.
   Measured here: CER 6.2% clean read speech (n=40), 21.5% conversation, 27.5% code-mixed, 14.8% Sinhala-only conversation (n=60); WER 35-43% (not a useful headline; spacing/ending variance).
   Why: it is the only candidate with held-out conversational and code-switching evidence, and our measurement agrees with the author's.
2. **Fallback / second candidate (do not default yet): `SinhaSpeech/whisper-small-sinhala-run12-best`** converted to CoreML for WhisperKit. 5.5% CER on read speech (n=40) is as good as Qwen; conversation performance is unknown (contaminated measurement). Promote only if the user's own recordings show it matches or beats Qwen, because it keeps a single runtime (WhisperKit) and avoids the share-alike licence question.
3. **Do not use stock Whisper (any size) for Sinhala.** Route Sinhala away from it; Whisper stays for English and other supported languages.
4. Gate "Sinhala" in the UI as lower-accuracy than English; expect roughly one wrong character in five on informal speech.
5. Before the phase ends, re-run `spikes/sinhala` on the user's recordings (below) and on an idle machine for speed.

## Routing-table rows

| Language / content | Engine | Model | Notes |
|---|---|---|---|
| Sinhala (si), read/dictation | MLX (mlx-audio-swift) | Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit @ 047217cb | CER ~6% (n=40); keep language unset or "Sinhala"; length-based `maxTokens`; loop guard |
| Sinhala conversation / Sinhala+English code-mixed | MLX (mlx-audio-swift) | same | CER ~21% (n=60), ~27% code-mixed; English mostly in Latin letters; label as preview |
| Sinhala, Whisper-family fallback | WhisperKit CoreML | SinhaSpeech/whisper-small-sinhala-run12-best (converted, TBD) | Candidate only; read-speech CER 5.5% (n=40); conversation unmeasured; conversion not yet done |
| Sinhala via stock Whisper large-v3 / turbo / base sizes | none | - | Do not route; 94-168% CER, hallucination loops |
| English / other Whisper-supported languages | WhisperKit CoreML | per other spikes | Unaffected by this spike. Note Qwen3-ASR also handles en/zh/es/fr/de but with 26-35% more errors than base for es/fr/de (card) |

## Sandbox/distribution flags

- **No non-sandboxed requirement identified.** MLX, mlx-audio-swift and WhisperKit run in-process; model weights are downloaded to the app container (outbound network entitlement needed only for the optional first-run download; fully local at inference).
- **Licence flag (share-alike):** Qwen-Sinhala weights are **CC BY-SA 4.0** (derived from OpenSLR52 CC BY-SA 4.0); base Qwen3-ASR-0.6B and mlx-community conversion are Apache-2.0. Redistributing or bundling modified weights carries attribution + share-alike obligations. Download-on-demand with attribution is cleaner than bundling in the app. Needs a lawyer/owner decision; not legal advice.
- **Training-data provenance flag:** Qwen-Sinhala conversational stage uses SPEAK-ASR YouTube data that has no licence ("used with permission" per the card; recordings belong to channels). Whisper fine-tunes advertise Apache-2.0 but were trained on CC BY-SA OpenSLR52 and, for SinhaSpeech, on datasets marked `license: unknown`. Declared Apache-2.0 on the weights is not a clean bill for share-alike or the YouTube material.
- **Evaluation data flag:** SPEAK-ASR YouTube audio and transcripts were used for internal evaluation only and are deliberately not committed; `.model-cache/sinhala-eval/` is gitignored. Do not publish transcripts or hypotheses derived from it.
- **Second runtime flag:** adopting Qwen needs MLX (Metal) alongside WhisperKit/CoreML: extra binary size, two code paths, GPU rather than ANE load, and a hard dependency on an mlx-audio-swift commit >= 01dec7c (feature extraction fix, PR #247). Pin the commit.
- **Dev-only tooling:** whisperkittools conversion needs Python 3.11 + torch 2.5.0 + an Xcode toolchain; it is build-time only and never ships. Hugging Face downloads were weights/config only; no `trust_remote_code`, no repo code executed.
- Download budget: about 3.4 GB total in `.model-cache/hf` (turbo, run12, Qwen) plus ~32 MB eval audio.

## Open questions for the user

1. Is Sinhala+English code-switching a core use case (meetings/interviews) or only occasional? This decides whether the Qwen/MLX second runtime is worth it versus a Whisper-small fine-tune on WhisperKit.
2. Are CC BY-SA 4.0 weights acceptable for this app's distribution model (download-on-demand with attribution vs bundling; open-source vs closed)?
3. Please provide clean real recordings (with transcripts, or willing to correct a draft) for a proper evaluation: (a) ~10 min of your own dictation-style Sinhala; (b) ~10 min of natural conversation or a meeting mixing Sinhala and English as you really speak; (c) ~5 min with background noise or a laptop mic at a distance; (d) any names/terms/numbers you commonly say. Prefer 16 kHz mono WAV or any audio the app can ingest; one-speaker and two-speaker variants. These stay local.
4. Are numbers, dates and digits expected as digits or words? (Qwen outputs mostly words as the training transcripts do, occasionally digits, including 3 false digit hallucinations in 8,748 clips.)
5. May I install Python 3.11 (e.g. via Homebrew or uv) outside the repo to run the whisperkittools conversion and verify run12 as CoreML?
6. Acceptable accuracy bar for the Sinhala release: is "preview quality" (~20% CER on conversation) acceptable at launch?
