import AppCore
import AppKit
import AudioCapture
import Diarization
import FeatureMenuBar
import FeatureSettings
import FeatureShell
import FeatureSupport
import Foundation
import Jobs
import Models
import Persistence
import Transcription

#if DEBUG
    import AppCoreTesting
#endif

/// Composition root: builds the concrete services behind the AppCore protocols and the feature models that use them.
///
/// Real implementations are wired where they exist (`AppDatabase`, `ModelManager`, `SystemHardwareTierProvider`, the
/// `PersistentJobQueue` with its engines);
/// `Placeholder*` stand-ins cover protocols without a real implementation yet (live session, meeting detector,
/// permissions, audio devices). Debug builds launched with `-UseMocks` (or `EARMARK_USE_MOCKS=1`) use fully in-memory
/// services with sample data and the `AppCoreTesting` model manager.
@MainActor
final class AppEnvironment {
    let services: AppServices
    let shell: ShellModel
    let menuBar: MenuBarModel
    private let activation: ActivationPolicyController

    init() {
        let services = Self.makeServices()
        self.services = services
        shell = ShellModel(services: services)
        menuBar = MenuBarModel(services: services)
        activation = ActivationPolicyController(settings: services.settings)
        menuBar.start()
        activation.start()
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

    private static func makeServices() -> AppServices {
        #if DEBUG
            if usesMocks { return mockServices() }
        #endif
        let database = openDatabase()
        let hardware = SystemHardwareTierProvider()
        let models = ModelManager(hardware: hardware)
        // One settings store instance: its change streams are tied to it, and the queue observes the same one.
        let settings = database.makeSettingsStore()
        return AppServices(
            jobQueue: makeJobQueue(database: database, models: models, hardware: hardware, settings: settings),
            transcripts: database.transcripts, meetings: database.meetings, models: models, live: PlaceholderLiveSession(),
            meetingDetector: PlaceholderMeetingDetector(), hardware: hardware, permissions: PlaceholderPermissions(),
            audioDevices: PlaceholderAudioDevices(), settings: settings)
    }

    /// The real file-transcription queue: WhisperKit (tokenizer provisioned by the model manager, so no implicit network,
    /// ENG-AC-14) and Apple Speech engines behind the router, offline diarization, auto-export and notifications.
    private static func makeJobQueue(
        database: AppDatabase, models: ModelManager, hardware: any HardwareTierProviding, settings: any SettingsStore
    ) -> any JobQueue {
        let whisper = WhisperKitEngine(models: models, tokenizerFolder: models.tokenizerFolder)
        let apple = AppleSpeechEngine()
        let decoder = AVFileDecoder()
        let pipeline = FileTranscriptionPipeline(decoder: decoder, identifier: WhisperLanguageIdentifier(engine: whisper))
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
