# 02 — Contracts (AppCore)

Status: **FROZEN (Phase 3 gate)**. Source of truth: `Packages/AppCore/Sources/AppCore/*.swift` (compiles under Swift 6 strict concurrency, warnings as errors; 9 smoke tests; swiftlint + swift-format clean). Changes need an SCR in `/specs/changes/`.

Rules: AppCore depends on Foundation + os only. Every cross-module call goes through these protocols/DTOs. Everything is `Sendable`; persisted types are `Codable`; IDs are typed (`ID<Tag>`). Mocks live in `AppCoreTesting` so implementers can build in parallel.

| File | Contracts | Serves (feature prefixes) | Implemented by |
|---|---|---|---|
| Foundation.swift | `ID<Tag>`, `EngineID`, `ModelID`, `TimeRange`, `LanguageCode`, `LanguageScore`, `LanguageMode` (default English), `AppError`, `AppLog` | all | AppCore |
| Domain.swift | `Segment`, `Word`, `Transcript` (header), `TranscriptDocument`, `Speaker`, `MediaAsset`, `TranscriptBookmark`, `IgnoreRule`, `ReplacementRule`, `CaptionPreset`, `DictationEntry` | EDIT, IGN, FR, LIB, LIVE, DICT | AppCore (types) |
| Audio.swift | `AudioChunk`, `AudioSource`, `AudioDeviceProviding`, `AudioFileDecoder`, `VoiceActivityDetector`, `TranscriptionEngine`, `LanguageIdentifier`, `EngineRouter`, `RoutingRequest/EnginePlan`, `TranscriptPostProcessor` | AUD, FILE, ENG, LANG, LIVE, IGN, FR | AudioCapture, Transcription, Processing |
| Models.swift | `HardwareTier/Profile/Providing`, `ModelDescriptor`, `ModelManaging` (`ensureAvailable` progress stream, delete, import), `LanguageCapabilityTable` (ADR-008) | ENG, LANG, SET, ONB | Models |
| Diarization.swift | `Diarizer`, `StreamingDiarizer`, `SpeakerTurn`, `LiveDiarizationEvent`, `maxLiveSpeakers = 4`, `SpeakerEmbedding(Provider)`, `VoiceProfile`, `SpeakerReconciler`; `TranslationEngine/Router`, `LanguagePair`, `TranslatedSegment` | DIA, MTG, LIVE, TRN | Diarization, Translation |
| Services.swift | `PermissionsServicing`, `HotkeyServicing`, `TextInserting`, `LiveSessionConfig/Controlling`, `CaptionLine`, `OverlayControlling` | DICT, LIVE, ONB, SET | Dictation, LiveCaptions, App |
| MeetingsJobsExport.swift | `MeetingDetector`, `MeetingPolicy` (default `askFirst`), `Recorder`, `Job`, `JobQueue`, `ExportOptions/Preset`, `Exporter` | MTG, FILE, EXP | Meetings, Persistence/Transcription (queue), Export |
| Persistence.swift | `TranscriptRepository` (+search, soft delete, purge), `MediaRepository`, `JobRepository`, `RuleRepository`, `PresetRepository`, `VoiceProfileRepository`, `MeetingRepository`, `DictationHistoryRepository`, `SettingsStore` | LIB, EDIT, IGN, FR, SET | Persistence |

## Notes / deliberate deviations from the brief
- `stream(source:options:)` takes `AsyncStream<AudioChunk>` (not `AudioSource`) so mixed / dual-lane inputs and tests compose without capture code.
- `LanguageIdentifier.identify` returns `[LanguageScore]` instead of a tuple array.
- `Transcript` is a header only; segments load via `TranscriptRepository.segments` to keep list views fast.
- Engines never download models; `ModelManaging.ensureAvailable` owns downloads and the UI shows its progress inline before a job proceeds.
- Live diarization is capped at `maxLiveSpeakers = 4`; `SpeakerReconciler.mapLiveSlots` maps live slots to the offline pass.
