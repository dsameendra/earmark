# fixtures/

Legally-usable test inputs for Earmark (transcription, diarization, dual-track capture, ignore/hallucination filter,
player click-to-seek). Audio/video binaries are gitignored (*.wav, *.mp4, *.webm, *.ogg ...); only MANIFEST.md, this README
and the small text references (txt / tsv / rttm / vtt) are committable. See MANIFEST.md for every file's source, license,
sha256, duration, speaker count and ground truth, and for what is still missing (Sinhala, real 2-speaker dialogue,
labelled accents, real noisy speech).

Layout
- en-single-librispeech/      F1 clean read speech, 1 speaker, 92 s, with transcript
- en-dialogue-synth2/         F2 synthetic 2-speaker dialogue with exact RTTM, mono mix + mic/remote tracks + stereo
- ami-es2004a-4spk-240s/      F3 AMI 4-speaker meeting window (3:00-7:00), RTTM + transcript, per-speaker headsets, dual-track stereo
- nonspeech-music-noise-silence/  F4 music, rain noise, silence, room tone, pink noise (expected transcript: empty)
- video-wikimedia-talk/       F5 CC0 talk video (webm + H.264 mp4) with VTT captions
- en-hard-librispeech-other/  F6a harder LibriSpeech speakers with transcripts
- en-noisy-synth-snr/         F6b speech + rain at 10 dB / 0 dB SNR, clean reference

Licensing notes
- CC BY 4.0 (LibriSpeech, AMI): keep attribution (Panayotov et al. 2015; AMI Meeting Corpus, Carletta et al. 2005).
- F4b rain is CC BY-SA 4.0 (Acabashi); F6b mixes inherit share-alike. Fine for internal tests; do not ship in the app bundle.
- Never copy fixtures into the app target or commit audio. Do not add user recordings here.

Rebuild (all from primary sources; use a venv and `python -I`; each download in its own empty dir)
1. Download LibriSpeech dev-clean / dev-other from https://www.openslr.org/12 and verify against md5sum.txt. Extract speakers
   84, 174, 2277 (dev-clean) and 3660, 116, 8288, 6455 (dev-other).
2. AMI: annotations ami_public_manual_1.6.2.zip and ES2004a Headset-0..3 / Mix-Headset from the AMI mirror
   (groups.inf.ed.ac.uk/ami); the mirror sometimes answers 503, retry. RTTM: .model-cache/datasets/ami/ref/ES2004a.rttm.
3. Wikimedia Commons files listed in MANIFEST.md (use a normal User-Agent; large files may be throttled, resume with curl -C -).
4. Concatenation/mixing was done with ffmpeg + numpy (16 kHz mono 16-bit PCM, 0.3-0.4 s gaps between LibriSpeech utterances;
   dialogue gaps 0.25-0.55 s; noise tiled to length and scaled to the target SNR). Verify checksums against MANIFEST.md.
