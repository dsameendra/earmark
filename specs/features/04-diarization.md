# 04 — Speaker Diarization (DIA)

Status: DRAFT (Phase 4). Owner: Diarization package. Sources: ADR-002, `specs/research/diarization.md` (§11 live), brief §5.6.

## Scope
Offline diarization of files, **live** speaker labels (v1 requirement), dual-track meeting labelling ("You" vs diarized remote), speaker rename/merge/reassign/colors, local voice profiles, live→offline reconciliation.

## AppCore dependencies
`Diarizer`, `StreamingDiarizer`, `DiarizationOptions`, `SpeakerTurn`, `LiveDiarizationEvent`, `maxLiveSpeakers`, `SpeakerReconciler`, `SpeakerEmbedding`, `SpeakerEmbeddingProvider`, `VoiceProfile`, `VoiceProfileRepository`, `Speaker`, `Segment.speakerID`, `LiveSessionControlling`, `CaptionLine`.

## Engines
Offline: FluidAudio Community-1 (SpeakerKit adapter swappable). Live: LS-EEND `.ami` primary (~1.1 s label latency, ≤ 4 speakers), Sortformer v2 (CC-BY weights) fallback. Measured (headset AMI, optimistic): LS-EEND pooled strict DER 15.7, offline 18.1; live vs offline disagree on 17–29 % of audio.

## Acceptance criteria
| ID | Criterion | Test |
|---|---|---|
| DIA-AC-01 | WHEN diarization is enabled for a job THE SYSTEM SHALL assign a `speakerID` to every non-ignored segment by maximum overlap with `SpeakerTurn`s. | unit |
| DIA-AC-02 | WHEN the speaker count is set to auto, min/max or exact THE SYSTEM SHALL pass it through `DiarizationOptions` and respect it. | integration |
| DIA-AC-03 | WHEN a live session has diarization on THE SYSTEM SHALL show provisional speaker labels within ~1.5 s of speech and mark them provisional. | integration / manual |
| DIA-AC-04 | WHEN more than `maxLiveSpeakers` (4) are detected live THE SYSTEM SHALL show "More speakers" for extras and defer their labelling to the offline pass. | unit |
| DIA-AC-05 | WHEN a live session or meeting ends THE SYSTEM SHALL run the offline pass on the recorded audio and remap live slots with `SpeakerReconciler.mapLiveSlots`, preserving user renames. | integration |
| DIA-AC-06 | WHEN labels change at reconciliation THE SYSTEM SHALL animate/flag the relabel once and not re-flip afterwards. | UI |
| DIA-AC-07 | WHEN a meeting is captured dual-track THE SYSTEM SHALL label the mic track "You" (or the user's name) and diarize only the remote track into Speaker 1…N. | integration |
| DIA-AC-08 | WHEN the mic picks up speaker bleed THE SYSTEM SHALL suppress false "You" segments using echo cancellation plus a voice-profile check, and SHALL NOT delete genuine simultaneous speech by a time-overlap gate alone. | integration / manual |
| DIA-AC-09 | WHEN the user renames a speaker THE SYSTEM SHALL update every segment, export, and the live view. | unit / UI |
| DIA-AC-10 | WHEN the user merges two speakers THE SYSTEM SHALL reassign all segments and keep one `Speaker`. | unit |
| DIA-AC-11 | WHEN the user reassigns a segment or word selection to another speaker THE SYSTEM SHALL split the segment at word boundaries if needed and support undo. | unit / UI |
| DIA-AC-12 | WHEN the user picks a speaker color THE SYSTEM SHALL persist it and use it in the editor, waveform regions and overlay. | UI |
| DIA-AC-13 | WHEN the user saves a voice profile THE SYSTEM SHALL store only the embedding and name locally via `VoiceProfileRepository`, and allow deletion. | unit |
| DIA-AC-14 | WHEN a new transcript's speaker embedding is within the calibrated distance of a stored profile THE SYSTEM SHALL auto-label that speaker. | integration |
| DIA-AC-15 | WHEN voice-profile matching finds split clusters for one person THE SYSTEM SHALL merge them by embedding distance before labelling. | unit |
| DIA-AC-16 | WHEN a diarizer throws THE SYSTEM SHALL continue the transcript without speaker labels and show a retry for diarization only. | unit (mock) |
| DIA-AC-17 | WHEN live diarization runs with ASR THE SYSTEM SHALL keep ASR throughput unchanged and cost diarization ≤ 20 % extra time (measured ≈ 15 %). | perf |
| DIA-AC-18 | WHEN attribution notices are required (CC-BY-4.0 models) THE SYSTEM SHALL list them in Settings → About / Models. | UI |

## Edge cases
Overlapping speech; one person split across slots; speakers joining late; silence on remote track; mono system mix; diarizer memory (offline 0.9 GB peak; LS-EEND 138 MB); Sortformer v2.1 licence is avoided.

## Non-functional
LS-EEND streaming 88× real time, ~1 % CPU; offline 264× on M3 Pro; peak memory < 1 GB offline.

## Unverified pending user run
Dual-track bleed handling on real captures; voice-match distance threshold (only 4 speakers calibrated, one series); behaviour on distant-mic audio (AMI headset mix is the easy case); Sortformer licence text re-check before shipping it.
