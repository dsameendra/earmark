# Sinhala ASR quality spike (Phase 0)

Status: DRAFT skeleton, measured results pending (see "Measurements"). All facts below were fetched on 2026-11-21 from the cited primary sources.
Machine: Apple M3 Pro, 18 GB, macOS 27.2.1. No timing benchmarks were run (other agents share the machine); timing scripts are deferred.

## 1. Public Sinhala test data

| Corpus | Content | License | Verdict |
|---|---|---|---|
| FLEURS (`google/fleurs`) | 102 languages | CC-BY-4.0 | **Has no Sinhala.** Verified: HF repo file list has no `si_*` directory; the third-party blog below says the same. |
| Common Voice (via Mozilla Data Collective since Oct 2025) | Sinhala listed only as "Spontaneous Speech 3.0", 21 clips / 0.12 h / 1 speaker, CC0-1.0; scripted set size unconfirmed | CC0-1.0 | Too small to evaluate. https://datacollective.mozillafoundation.org/datasets/cmmysetwg00fkmf07v0akjit6 |
| OpenSLR 52 | ~185K read utterances, 478 speakers, ~224 h (hours per blog; OpenSLR page gives no hours), Google crowd-sourced | CC BY-SA 4.0 | Training set of essentially every public fine-tune. 71% of a speaker-disjoint test set reads sentences also present in training (Nerdstorm card). Any SLR52 number is flattered for fine-tunes. https://www.openslr.org/52/ |
| OpenSLR 30 | Multi-speaker Sinhala TTS corpus, Google, 699 MB | CC BY-SA 4.0 | Not named in any candidate's training list. Studio-quality read speech. https://www.openslr.org/30/ |
| `SPEAK-ASR/youtube-sinhala-asr` | 4,037 clips, 9.1 h, 111 videos, 34 YouTube channels, flags `is_code_mixed` (54%), `has_noise`, `uploader` | **No licence** (published without one; recordings belong to channels) | Only public conversational / code-mixed set. Internal evaluation only, never redistribute, never ship. https://huggingface.co/datasets/SPEAK-ASR/youtube-sinhala-asr |
| `SinhaSpeech/sinhala-asr-data` | 154,828 clips pooled: ~97% OpenSLR52, ~2% YouTube, 0.6% BizBrains, 0.6% Linga | `license: unknown` | Provenance unclear; not used for evaluation here. https://huggingface.co/datasets/SinhaSpeech/sinhala-asr-data |

Conclusion: no public, clean, licensed, mixed Sinhala+English test set exists. The only code-mixed audio is the unlicensed SPEAK-ASR YouTube set.

TODO sections below are filled in as measurements finish.
