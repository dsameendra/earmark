# Fixture manifest

Access date for every download: 2026-11-21. Audio/video binaries are gitignored; this manifest, README and the small
text references (txt/tsv/rttm/vtt) are committable. Durations from ffprobe/afinfo; sha256 of the file as stored here.
Rebuild instructions are in README.md. "Derived" = made by us from the primary source with ffmpeg/numpy (no new content).

## Files

| ID | Path (under fixtures/) | Kind | Dur (s) | Ch | Speakers | Ground truth | License | Primary source | sha256 |
|---|---|---|---|---|---|---|---|---|---|
| F1 | en-single-librispeech/en-single-librispeech.wav | EN single speaker, read speech, 16 kHz mono; 24 consecutive utterances of spk 84 (F), ch 121123, 0.4 s gaps (derived) | 91.98 | 1 | 1 | en-single-librispeech.txt (+ .utterances.tsv with times) | CC BY 4.0 (audio: LibriVox, public domain) | https://www.openslr.org/12 dev-clean.tar.gz | 8906e4381a7f3ea83032391569880c749aadd5ed041fb6614a6f61c1f36cecfa |
| F2a | en-dialogue-synth2/mix_mono.wav | EN 2-speaker "dialogue", mono mix. SYNTHETIC: alternating LibriSpeech utterances (spk 174 M = SPK_A, spk 2277 = SPK_B), no overlap, 0.25-0.55 s gaps; sentences unrelated (not conversational) | 131.67 | 1 | 2 | reference.txt / reference.tsv / reference.rttm (exact) | CC BY 4.0 | https://www.openslr.org/12 dev-clean.tar.gz | 9a4379c58bbd90ac6854b03b9e89d7b6bc33d5a3cfeb768c975e87f5a38d2bbd |
| F2b | en-dialogue-synth2/track_mic_SPK_A.wav | dual-track sim: "mic" track = SPK_A only | 131.67 | 1 | 1 | rttm (SPK_A rows) | CC BY 4.0 | derived from F2a | a2d82847c5af5621d7f05a0d544f1c9d7cd452f6ea681d05403d27ca372ff1a6 |
| F2c | en-dialogue-synth2/track_remote_SPK_B.wav | dual-track sim: "remote" track = SPK_B only | 131.67 | 1 | 1 | rttm (SPK_B rows) | CC BY 4.0 | derived from F2a | e9348c04975bd0450dd6f7d524408493802d56175ffd198aae772ccedbcb95f2 |
| F2d | en-dialogue-synth2/stereo_L-mic_R-remote.wav | L = mic (SPK_A), R = remote (SPK_B) | 131.67 | 2 | 2 | reference.rttm / reference.txt (as F2a) | CC BY 4.0 | derived from F2a | 3d0b7d59f7b6294bb3a5341961165e686ece98a7c6a30c8490aceee202b24135 |
| F3 | ami-es2004a-4spk-240s/ES2004a_180-420s.wav | AMI ES2004a (scenario meeting), Mix-Headset, window 180-420 s of the meeting, 16 kHz mono (derived) | 240.00 | 1 | 4 (MEO015, FEE013, MEE014, FEE016) | reference.rttm (window-shifted, from cached AMI RTTM) + reference.txt (turn-level transcript built from AMI NXT words XML, speaker-labelled) | CC BY 4.0 | https://groups.inf.ed.ac.uk/ami/corpus/ ; annotations https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip (sha256 b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d) | 2bdd9dafdad52a37daf5d625d49a72fee99ca0b67150dc37315dd36ea065ff69 |
| F3a-d | ami-es2004a-4spk-240s/headsets/ES2004a_180-420s_Headset-{0..3}_{MEO015,FEE013,MEE014,FEE016}.wav | per-speaker close-talk headset channels, same window (derived from AMI Headset-N.wav) | 240.00 | 1 | 1 each (ch0 A=MEO015, ch1 B=FEE013, ch2 C=MEE014, ch3 D=FEE016 per AMI meetings.xml) | rttm rows for that speaker; headsets have cross-talk bleed | CC BY 4.0 | AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Headset-N.wav | H0 9b80af7aa2c1f1ec94f23a9be2e2899c7f4c0db070a95bfa213c8d732f4d79ab; H1 abec4051ca7ca5f55447151d1ede2fe54f8b1ffc37b9b23a98da972b1ec5730f; H2 5448f82dd5dc2afd472b1282f242f03c7c3ff0638aac6a0a0613f6b6b6576581; H3 59e0724d0c902ca608ee0927da388fdb1e1f96cd6c844261cacdac3f163d99a6 |
| F3e | ami-es2004a-4spk-240s/headsets/remote_mix_FEE013+MEE014+FEE016.wav | sum of 3 headsets = simulated "remote" side (derived) | 240.00 | 1 | 3 | rttm minus MEO015 | CC BY 4.0 | derived from F3a-d | a0d7fb3be162398cb76e8b44b25610f3a3ea768540b26fcdec688cf87f50e17d |
| F3f | ami-es2004a-4spk-240s/dual_L-mic-MEO015_R-remote-others.wav | stereo dual-track meeting sim: L = MEO015 headset (mic), R = other 3 (remote) | 240.00 | 2 | 4 | reference.rttm / reference.txt | CC BY 4.0 | derived from F3a-e | 1f13eb55265e8ddbe2531451bcadf93e361b83af823b313ce067d4cd4a085edf |
| F4a | nonspeech-music-noise-silence/music_clementi_sonatina1_andante.wav | solo piano music, 16 kHz mono (derived from .ogg; orig sha256 9a4379c58bbd90ac6854b03b9e89d7b6bc33d5a3cfeb768c975e87f5a38d2bbd) | 80.60 | 1 | 0 | expected transcript: empty | CC0 (per Commons metadata), performer Alessio Cesaroni | https://commons.wikimedia.org/wiki/File:Clementi,_Sonatina_N.1_-_2_Mov._Andante.ogg | 2b59d056349bf656e18a5ec6576326ebaf9624fa055c1698463a6642799d4af7 |
| F4b | nonspeech-music-noise-silence/noise_rain_wind_london.wav | real-world rain+wind ambience, 16 kHz mono (derived; orig 44.1 kHz stereo sha256 21f958d0842eee1dfa938dc62758eaca3415fe3f54caa15af16288d88d26e59d) | 34.30 | 1 | 0 | expected transcript: empty | CC BY-SA 4.0, by Acabashi (attribution + share-alike; internal test use) | https://commons.wikimedia.org/wiki/File:Rain_and_wind_in_London_2026_08_28.wav | 6acaca79dec378b62655a52885d04b1d6668278a9fc2ea58348055245d399fc2 |
| F4c | nonspeech-music-noise-silence/silence_digital_60s.wav | digital silence (generated: ffmpeg anullsrc) | 60.00 | 1 | 0 | empty | n/a (generated, no third-party content) | generated | 51158971af880fb66f57e9ec32013dc964c3044cb5c1d8ed38c59f1d65a306d5 |
| F4d | nonspeech-music-noise-silence/silence_roomtone_synth_60s.wav | very quiet brown noise (~-50 dBFS) as room tone (generated) | 60.00 | 1 | 0 | empty | n/a (generated) | generated | 5a1b568ab0af47750969fa9c82f2e9e5e1e91a825741a06beb77cad203f34b17 |
| F4e | nonspeech-music-noise-silence/noise_pink_synth_60s.wav | pink noise (~-20 dBFS, generated) | 60.00 | 1 | 0 | empty | n/a (generated) | generated | 4947e744e99eef6cba1b9c28cba1214a2fd9a7449b5f8051ae14d0389f52a9e1 |
| F5a | video-wikimedia-talk/talk.webm | 1080p VP9/Opus talk video, single speaker (Eli Asikin-Garmager), embedded WebVTT track | 284.00 | 2 | 1 | talk.en.vtt (extracted from the file's WebVTT stream, 4 s caption blocks = coarse timing, human-made captions, not verified word-for-word) | CC0 | https://commons.wikimedia.org/wiki/File:Research_and_Privacy_on_Wikipedia_-_Wikimania_2025_Lightning_Talk_-_Eli_Asikin-Garmager.webm | 8272a888dac53cf8176205ccf7daf74aa3242f39dfb2278942e14ce080fa99b1 |
| F5b | video-wikimedia-talk/talk_h264.mp4 | same, transcoded 1280 px H.264/AAC for AVFoundation/AVPlayer (derived; AVPlayer WebM/VP9 support not verified) | 283.46 | 2 | 1 | talk.en.vtt | CC0 | derived from F5a | cc1ceec8845e667a19f2d7e8f441d6a94f5cc2ad4178370b984cdb3e5ef65957 |
| F6a | en-hard-librispeech-other/other_{3660,116,8288,6455}.wav | "hard" LibriSpeech dev-other speakers (variable accents/recording quality; no accent labels), ~37 s each, consecutive utterances, 0.3 s gaps (derived). spk 3660 M, 116 M, 8288 M, 6455 F | 37.79 (116), 37.54 (3660), 39.09 (8288), 36.13 (6455) | 1 | 1 each | other_<spk>.txt | CC BY 4.0 | https://www.openslr.org/12 dev-other.tar.gz (sha256 12661c48e8c3fe1de2c1caa4c3e135193bfb1811584f11f569dd12645aa84365) | 116 785c8fca28f408e7afc01f3fa1510d5f34679fae4d33b98d756ca4617c2df693; 3660 cd02cb9331c3d2cb96fd5bb74c9b1ba38aeb9879f5f9b3b2f17932723abe77ef; 8288 def686ca5e3a58eb1ab3325a8fe77678bb6a503866adbb31ab0ef8703d016e95; 6455 e1ad75a18b53dcd5fdbeffc5b434daabf9cdaac24a4c237721bd0aee981efbbf |
| F6b | en-noisy-synth-snr/speech84_plus_rain_snr{10,0}dB.wav, clean_ref.wav | spk 84 clean speech (30 s of utterances) + F4b rain at 10 dB / 0 dB SNR, SYNTHETIC mix; clean_ref = same speech without noise | 32.47 | 1 | 1 | noisy.txt | speech CC BY 4.0; noise CC BY-SA 4.0 (derived mix inherits share-alike) | LibriSpeech dev-clean + F4b | snr10 e415f5b6748f598e65a87e9edaa32450871578bc4810211df28dc820dab62380; snr0 0037f835c56811cbe501e5c6506625c775d0cfeccd4183d377dd5553207c3415; clean 7fa70f210f80ded8e24824f8649600016252958fe60d330bb0072b02b3660bbb |


## Source archives (verified)

| Archive | URL | Size | Check |
|---|---|---|---|
| LibriSpeech dev-clean.tar.gz | https://www.openslr.org/resources/12/dev-clean.tar.gz | 337,926,286 B | md5 42e2234ba48799c1f50f24a7926300a1 matches openslr md5sum.txt; sha256 76f87d090650617fca0cac8f88b9416e0ebf80350acb97b343a85fa903728ab3 |
| LibriSpeech dev-other.tar.gz | https://www.openslr.org/resources/12/dev-other.tar.gz | ~314 MB | md5 c8d0bcc9cca99d4f8b62fcc847357931 matches openslr; sha256 12661c48e8c3fe1de2c1caa4c3e135193bfb1811584f11f569dd12645aa84365 |
| AMI ES2004a Headset-0..3.wav (full, 1049.35 s) | AMICorpusMirror (see F3a-d); mirror intermittently returns 503, retry later | ~34 MB each | afinfo-verified; sha256 H0 abb4917719c6e033b066fbd400b6d37fe46ddd62c89b513f77016a51f54e2ad1, H1 9be8e84e4ef93ea7eef669470cd6db017856f38f7321e0054199ad7393a1199c, H2 a4f2f8ea7d965ede2c010e36bfc31c14c7792d07419bd5bc9519c8ddd1c8bc28, H3 5b3cf59816d5160d77ff00315dc7f6db816c175edb65e0d61691679fae633572 |
| AMI ES2004a.Mix-Headset.wav | reused from .model-cache/datasets/ami/audio (diarization spike, not re-downloaded) | 34 MB | sha256 3e2560b19bee6952c7c7ce041b0f1ea8a7ea9468044c4eea79d2a2c67e24ab0f |
| AMI reference RTTM ES2004a | reused from .model-cache/datasets/ami/ref/ES2004a.rttm (provenance per the diarization spike; presumed BUT AMI-diarization-setup; not independently verified) | 260 lines | UEM 0-1049.35 s |

## Sinhala evaluation sets (T25; access date 2026-11-22; NOT under fixtures/, gitignored `.model-cache/`)

FLEURS has no Sinhala (verified, see specs/research/sinhala-asr.md) and Common Voice Sinhala is a handful of clips, so no new
download was made: the T25 measurements reuse the sets the Sinhala spike built under `.model-cache/sinhala-eval/` (resolved by
walking up from the test file, so it works from worktrees). Rebuild with `spikes/sinhala/prep_slr30_eval.py` and `prep_speak_eval.py`.

| ID | Path | Content | Licence | Use |
|---|---|---|---|---|
| S1 | .model-cache/sinhala-eval/slr30_wav/ + manifest.jsonl | 40 clean read utterances, 12 speakers, ~3 min, OpenSLR 30 (texts also in SLR52 excluded) | CC BY-SA 4.0 | WER/CER/RTF of `QwenSinhalaEngine`; `{en, si}` language-ID accuracy of `WhisperLanguageIdentifier` |
| S2 | .model-cache/sinhala-eval/speak/ + manifest.jsonl | 60 conversational / code-mixed clips (30 mixed, 30 Sinhala-only) from SPEAK-ASR/youtube-sinhala-asr, 5 channels held out of the Qwen training | none (unlicensed; internal evaluation only) | accuracy aggregates only; never commit or publish clips, transcripts or hypotheses |

## Missing / not covered

- Sinhala and mixed Sinhala-English fixtures: see the "Sinhala evaluation sets" section (small, partly unlicensed; no licensed Sinhala+English set exists).
- Real (non-synthetic) 2-speaker conversation with natural turn-taking, overlap and per-speaker channels: NOT obtained. AMI meetings are 4-speaker; F2 is synthetic (clean, no overlap, unrelated sentences). Candidates: pick a 2-active-speaker stretch of an AMI meeting (rttm-driven), Fisher/CallHome (LDC, not free), or record our own consented call.
- Labelled accented English: Common Voice was not attempted (believed to require a login/agreement; not verified); VoxPopuli (CC0) en_accented is 2 x ~2.5 GB parquet and en test ~0.9 GB, over the size budget. F6a (LibriSpeech dev-other) is only a proxy: harder speakers, no accent metadata.
- Real noisy speech (cafe/street/phone line): only synthetic SNR mixes (F6b) plus rain/pink noise. MUSAN (CC BY 4.0, ~11 GB) was not downloaded; Freesound needs an API key.
- Real video with 2+ speakers and a burned-in/visual speaker change (for diarization-with-video): not covered; F5 is a single speaker.
- AMI word-level transcript is turn-grouped by us (gap < 1 s) and keeps AMI disfluencies/"Um"; RTTM comes from a different pipeline than the NXT words so boundaries differ by tens of ms.
- Overlap/backchannel-heavy, multilingual code-switching, long (> 5 min) files: not covered except full AMI meetings available in .model-cache/datasets/ami.
