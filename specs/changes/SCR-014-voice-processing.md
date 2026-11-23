# SCR-014: Voice processing (offline speech enhancement before transcription)

Status: implemented. Additive: no persisted data changes meaning. Builds on SCR-013 (the add sheet, `JobSettings`, re-run).

## AppCore

- `VoiceProcessingLevel { off, light, standard, strong }` (`String` raw values, `Codable`, `CaseIterable`). `init(storedValue:)` maps
  `nil` and unknown strings to `.off`.
- `JobSettings.voiceProcessing: VoiceProcessingLevel` (default `.off`). Decoded with `decodeIfPresent` through the lenient
  `init(storedValue:)`, so journals written before this change, and values from a newer build, load as `.off`.
- `TranscriptionOptions.voiceProcessing` (default `.off`), set by the job runner from `job.settings`.

## AudioCapture

- `VoiceEnhancer`: a deterministic, causal, sample-streaming enhancer for 16 kHz mono Float32 (Accelerate/vDSP). Stages: optional
  de-click (strong only), 80 Hz Butterworth high-pass, STFT noise reduction (512 periodic sqrt-Hann frames, hop 256) with a per-bin
  noise floor from minimum statistics, decision-directed Wiener gains with over-estimation and a per-level gain floor, a
  skip-if-clean crossfade driven by the running SNR estimate, a slow speech-gated AGC towards about -20 dBFS active-speech RMS
  (boost capped per level, never above a -1 dBFS peak ceiling, 1 dB dead band), and a soft limiter above -1 dBFS.
  Output has exactly the input's sample count; the result does not depend on how the input is split into calls; memory is constant.
- `VoiceProcessingDecoder`: an `AudioFileDecoder` wrapper. Blocks keep their original `startSeconds` and sizes, so media time, word
  timestamps and chunk cuts are untouched. On resume (decode start > 0) the enhancer is warmed up on 1 s of pre-roll that is
  discarded. State is not journaled, so a resumed run can differ slightly from an uninterrupted one near the checkpoint; it is
  deterministic for a given start point.

| Level | Gain floor | Noise over-estimate | Max boost | Bypass above / full below (est. SNR) | De-click |
|---|---|---|---|---|---|
| Light | -9 dB | 1.0 | 9 dB | 32 / 24 dB | no |
| Standard | -15 dB | 1.3 | 15 dB | 38 / 28 dB | no |
| Strong | -22 dB | 1.8 | 20 dB | 45 / 32 dB | yes |

## Transcription and Jobs

- `FileTranscriptionPipeline.run` wraps its decoder in `VoiceProcessingDecoder` when `options.voiceProcessing != .off`, so the VAD,
  cut points, language ID and engine all see the processed audio; checkpoints and progress are unchanged. Re-runs (SCR-013) use the
  same path. Per-segment retranscription and live captions/meetings are not processed (deferred).

## Features

- Transcribe sheet: "Voice processing" toggle with a level picker (Light, Standard, Strong) and the line "Reduces background noise
  and evens out volume before transcribing. Your original file is never changed." The per-file Customize popover offers "Same as
  batch", Off, Light, Standard, Strong (`FileOverride.voiceProcessing`).
- Setting `files.voiceProcessing` (`String`, a `VoiceProcessingLevel` raw value; absent means off) is both the remembered sheet
  choice and the Settings default ("Voice processing default" in Settings > General, Adding files). `FileJobSettings.load` and
  `save` carry it, so the no-sheet add path uses it too.
- Editor Re-transcribe popover: one "Voice processing" picker row; `RerunRequest.voiceProcessing` feeds the job's settings.

## Not in this change (deferred)

- Meeting finalization pass, live captions, dictation and single-segment retranscription are not enhanced.
- No journaled enhancer state: resume re-warms on pre-roll.
- Whisper is already noise-robust; the evaluation in the change notes shows where processing helps and where it does not, which is
  why the default stays Off.
