import AppCore
import AppKit
import AudioCapture
import Dictation
import Diarization
import FeatureMenuBar
import FeatureSettings
import FeatureShell
import FeatureSupport
import Foundation
import Jobs
import LiveCaptions
import Models
import Permissions
import Persistence
import Processing
import Transcription

#if DEBUG
    import AppCoreTesting
#endif

/// Composition root: builds the concrete services behind the AppCore protocols and the feature models that use them.
///
/// Real implementations are wired where they exist (`AppDatabase`, `ModelManager`, `SystemHardwareTierProvider`, the
/// `PersistentJobQueue` with its engines);
/// `Placeholder*` stand-ins cover protocols without a real implementation yet (meeting detector). Live captions
/// (`LiveSessionOrchestrator` and overlay) and dictation are wired here too. Debug builds launched with `-UseMocks` (or `EARMARK_USE_MOCKS=1`) use fully in-memory
/// services with sample data and the `AppCoreTesting` model manager.
@MainActor
final class AppEnvironment {
    let services: AppServices
    /// Full wiring for the Settings scene (rules and presets persist through the database).
    let settingsDependencies: SettingsDependencies
    let shell: ShellModel
    let menuBar: MenuBarModel
    private let activation: ActivationPolicyController
    /// Live captions and dictation runtime (nil under `-UseMocks`); held here so they live as long as the app.
    private let live: LiveRuntime?
    private let dictation: DictationRuntime?

    init() {
        let composition = Self.makeServices()
        let services = composition.services
        self.services = services
        settingsDependencies = composition.settingsDependencies
        live = composition.live
        dictation = composition.dictation
        shell = ShellModel(services: services)
        menuBar = MenuBarModel(services: services)
        activation = ActivationPolicyController(settings: services.settings)
        menuBar.start()
        activation.start()
        live?.extras.start()
        if let dictation {
            let store = services.settings
            let controller = dictation.controller
            Task { await DictationSettingsBridge.run(store: store, controller: controller) }
        }
        // FILE-AC-08: jobs left running by a crash or quit continue from their last checkpoint.
        let queue = services.jobQueue
        Task { await queue.resumeInterrupted() }
    }

    /// `true` when the debug mock flag is set.
    static var usesMocks: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-UseMocks") || ProcessInfo.processInfo.environment["EARMARK_USE_MOCKS"] == "1"
        #else
            false
        #endif
    }

    /// Everything `init` needs from the composition.
    private struct Composition {
        var services: AppServices
        var settingsDependencies: SettingsDependencies
        var live: LiveRuntime?
        var dictation: DictationRuntime?
    }

    struct LiveRuntime {
        let session: LiveSessionOrchestrator
        let overlay: CaptionOverlayController
        let extras: LiveExtrasService
    }

    struct DictationRuntime {
        let controller: DictationController
        let hud: DictationHUDController
        let hotkeys: GlobalHotkeyService
    }

    private static func makeServices() -> Composition {
        #if DEBUG
            if usesMocks {
                let mocks = mockServices()
                return Composition(services: mocks, settingsDependencies: .standalone(store: mocks.settings))
            }
        #endif
        let database = openDatabase()
        let hardware = SystemHardwareTierProvider()
        let models = ModelManager(hardware: hardware)
        // One settings store instance: its change streams are tied to it, and the queue observes the same one.
        let settings = database.makeSettingsStore()
        let permissions = PermissionsService()
        let audioDevices = AudioDeviceProvider()
        // One engine instance each, shared by file jobs, live captions and dictation: WhisperKit holds a single resident model.
        let whisper = WhisperKitEngine(models: models, tokenizerFolder: models.tokenizerFolder)
        let apple = AppleSpeechEngine()
        let engines: [EngineID: any TranscriptionEngine] = [whisper.id: whisper, apple.id: apple]

        let live = makeLive(
            database: database, models: models, hardware: hardware, settings: settings, permissions: permissions,
            audioDevices: audioDevices, engines: engines)
        let dictation = makeDictation(
            database: database, models: models, hardware: hardware, settings: settings, permissions: permissions,
            engines: engines)
        let dictationControl = DictationMenuControl.make(controller: dictation.controller, settings: settings)

        let services = AppServices(
            jobQueue: makeJobQueue(
                database: database, models: models, hardware: hardware, settings: settings, whisper: whisper, apple: apple),
            transcripts: database.transcripts, meetings: database.meetings, models: models, live: live.session,
            meetingDetector: PlaceholderMeetingDetector(), hardware: hardware, permissions: permissions,
            audioDevices: audioDevices, settings: settings, media: database.media, presets: database.presets,
            liveExtras: live.extras, dictation: dictationControl)
        let settingsDependencies = SettingsDependencies(
            store: settings, models: models, hardware: hardware, audioDevices: audioDevices, permissions: permissions,
            rules: database.rules, presets: database.presets, transcripts: database.transcripts,
            hotkeyDiagnostics: dictation.hotkeys, retryHotkeys: { [controller = dictation.controller] in await controller.retryHotkeyRegistration() },
            overlayPlacement: live.overlay)
        return Composition(services: services, settingsDependencies: settingsDependencies, live: live, dictation: dictation)
    }

    /// Live captions: the orchestrator over the `AudioCapture` sources, the router-chosen engine, LS-EEND streaming
    /// diarization and the shared post-processing chain, plus the caption overlay.
    private static func makeLive(
        database: AppDatabase, models: ModelManager, hardware: any HardwareTierProviding, settings: any SettingsStore,
        permissions: any PermissionsServicing, audioDevices: AudioDeviceProvider, engines: [EngineID: any TranscriptionEngine]
    ) -> LiveRuntime {
        let audio = LiveAudioProvider(permissions: permissions, settings: settings, deviceProvider: audioDevices)
        let provider = RouterEngineProvider(
            router: DefaultEngineRouter(), hardware: hardware, models: models, engine: { engines[$0] },
            explicitModel: {
                let raw = await settings.value(for: SettingsKey.preferredModel, as: String.self)
                guard let raw, !raw.isEmpty else { return nil }
                return ModelID(raw)
            })
        let rules = database.rules
        let session = LiveSessionOrchestrator(
            audio: audio, engines: provider, transcripts: database.transcripts, postProcessor: PostProcessingChain(),
            postProcessingContext: {
                let ignore = ((try? await rules.ignoreRules()) ?? []).filter { $0.isEnabled && $0.deletedAt == nil }
                let replace = ((try? await rules.replacementRules()) ?? []).filter { $0.isEnabled && $0.deletedAt == nil }
                return PostProcessingContext(
                    ignoreRules: ignore, replacementRules: replace,
                    applyReplacements: await settings.value(for: SettingsKey.applyReplacementsByDefault, as: Bool.self) ?? true,
                    enableHallucinationFilter: await settings.value(for: SettingsKey.hallucinationFilterEnabled, as: Bool.self) ?? true)
            },
            diarizer: LSEENDStreamingDiarizer(models: models))
        let overlay = CaptionOverlayController(settings: settings)
        let extras = LiveExtrasService(
            session: session, audio: audio, overlay: overlay,
            presetStore: CaptionPresetStore(repository: database.presets, settings: settings), settings: settings)
        return LiveRuntime(session: session, overlay: overlay, extras: extras)
    }

    /// Dictation: global hotkey (event tap with an `NSEvent` fallback), mic source, engine routed for `.dictation`,
    /// text insertion, HUD and history. The controller is started at launch; a missing permission only disables the hotkey.
    private static func makeDictation(
        database: AppDatabase, models: ModelManager, hardware: any HardwareTierProviding, settings: any SettingsStore,
        permissions: any PermissionsServicing, engines: [EngineID: any TranscriptionEngine]
    ) -> DictationRuntime {
        let hud = DictationHUDController()
        let routed = RoutedEngineProvider(
            router: DefaultEngineRouter(), tier: { hardware.profile.tier }, installedModels: { await models.installedModels() },
            engines: engines)
        let hotkeys = GlobalHotkeyService(source: FallbackHotkeySource())
        let controller = DictationController(
            dependencies: DictationDependencies(
                hotkeys: hotkeys,
                makeAudioSource: { uid in MicrophoneSource(deviceUID: uid, permissions: permissions) },
                engineProvider: routed.provider,
                pipeline: DictationPipeline(postProcessor: PostProcessingChain(), rules: database.rules),
                inserter: TextInserter.system(), history: DictationHistory(repository: database.dictationHistory),
                settings: settings, permissions: permissions, hud: hud, notifier: SystemDictationNotifier(),
                onboarding: AccessibilityOnboardingPresenter()))
        return DictationRuntime(controller: controller, hud: hud, hotkeys: hotkeys)
    }

    /// The real file-transcription queue: WhisperKit (tokenizer provisioned by the model manager, so no implicit network,
    /// ENG-AC-14) and Apple Speech engines behind the router, offline diarization, auto-export and notifications.
    private static func makeJobQueue(
        database: AppDatabase, models: ModelManager, hardware: any HardwareTierProviding, settings: any SettingsStore,
        whisper: WhisperKitEngine, apple: AppleSpeechEngine
    ) -> any JobQueue {
        let decoder = AVFileDecoder()
        // Language ID must use the model the plan routed to; a fixed model would swap WhisperKit's single resident model.
        let whisperID = whisper.id
        let pipeline: PipelineFactory = { plan in
            let model = plan.assignments.first { $0.engine == whisperID }?.model
            return FileTranscriptionPipeline(
                decoder: decoder, identifier: model.map { WhisperLanguageIdentifier(engine: whisper, model: $0) })
        }
        return PersistentJobQueue(
            services: JobQueueServices(
                jobs: database.jobs, transcripts: database.transcripts, media: database.media, rules: database.rules,
                settings: settings, models: models, hardware: hardware, engines: [whisper.id: whisper, apple.id: apple],
                pipeline: pipeline, decoder: decoder, diarizer: FluidAudioDiarizer(models: models),
                autoExport: WatchFolderExport.provider(settings: settings, presets: database.presets),
                notifier: SystemJobNotifier()))
    }

    private static func openDatabase() -> AppDatabase {
        let log = AppLog.logger("AppEnvironment")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = (support ?? FileManager.default.temporaryDirectory).appendingPathComponent("Earmark/earmark.sqlite")
        do {
            return try AppDatabase.open(at: url)
        } catch {
            log.error("Falling back to in-memory database: \(String(describing: error), privacy: .public)")
            // An in-memory database cannot fail to open in practice; if it does there is nothing sensible left to run.
            do { return try AppDatabase.inMemory() } catch { fatalError("Cannot open any database: \(error)") }
        }
    }

    #if DEBUG
        private static func mockServices() -> AppServices {
            let sample = [
                Transcript(title: "Weekly sync", source: .meeting, duration: 1830, languages: ["en"]),
                Transcript(title: "සම්මුඛ සාකච්ඡාව", source: .file, duration: 412, languages: ["si"]),
            ]
            let model = ModelDescriptor(
                id: "mock/asr", displayName: "Mock ASR", kind: .asr, runtime: .coreML, languages: [.english], sizeBytes: 100,
                license: LicenseInfo(spdx: "MIT"))
            var services = AppServices.preview(transcripts: sample)
            services.models = MockModelManager(descriptors: [model])
            return services
        }
    #endif
}

/// Applies the Dock-icon preference as the app's activation policy (MENU-AC-08) and follows changes.
@MainActor
final class ActivationPolicyController {
    private let settings: any SettingsStore
    private var task: Task<Void, Never>?

    init(settings: any SettingsStore) { self.settings = settings }

    func start() {
        guard task == nil else { return }
        let settings = settings
        task = Task { [weak self] in
            self?.apply(showDockIcon: await GeneralSettingsModel.loadShowDockIcon(from: settings))
            for await _ in settings.changes(for: SettingsKey.showDockIcon) {
                self?.apply(showDockIcon: await GeneralSettingsModel.loadShowDockIcon(from: settings))
            }
        }
    }

    private func apply(showDockIcon: Bool) {
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        guard NSApplication.shared.activationPolicy() != policy else { return }
        NSApplication.shared.setActivationPolicy(policy)
        if showDockIcon { NSApplication.shared.activate() }
    }
}
