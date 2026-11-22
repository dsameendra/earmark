import AppCore
import AppCoreTesting
import FeatureHome
import FeatureQueue
import FeatureSupport
import Foundation
import Testing

private func model(_ id: ModelID, _ name: String, languages: Set<LanguageCode>, kind: ModelKind = .asr) -> ModelDescriptor {
    ModelDescriptor(
        id: id, displayName: name, kind: kind, runtime: .coreML, languages: languages, sizeBytes: 1, license: LicenseInfo(spdx: "MIT"))
}

private func job(_ name: String, _ state: JobState, progress: Double = 0) -> Job {
    Job(kind: .transcribeFile, state: state, input: URL(fileURLWithPath: "/tmp/\(name)"), progress: progress)
}

@Suite @MainActor struct QueueTests {
    @Test func onlyRunningAndPausedRowsHaveDeterminateProgress() {
        #expect(QueueFormatting.showsProgress(for: .running))
        #expect(QueueFormatting.showsProgress(for: .paused))
        for state in [JobState.pending, .completed, .cancelled, .failed] {
            #expect(!QueueFormatting.showsProgress(for: state))
        }
        #expect(QueueFormatting.fraction(.nan) == 0)
        #expect(QueueFormatting.fraction(.infinity) == 0)
        #expect(QueueFormatting.fraction(-1) == 0)
        #expect(QueueFormatting.fraction(4) == 1)
    }

    @Test func clearFinishedPreservesFailedAndActiveWork() async throws {
        let completed = job("done", .completed)
        let cancelled = job("cancelled", .cancelled)
        let failed = job("failed", .failed)
        let pending = job("waiting", .pending)
        let queue = QueueModel(services: .preview(jobs: [completed, cancelled, failed, pending]))
        let observing = Task { await queue.run() }
        defer { observing.cancel() }
        #expect(await eventually { !queue.isLoading })
        await queue.clearFinished()
        #expect(Set(queue.jobs.map(\.id)) == [failed.id, pending.id])
        #expect(!queue.hasFinished)
    }

    @Test func clearQueueRemovesAllStatesThroughTheService() async {
        let jobs = PlaceholderJobQueue(seed: [
            job("active", .running), job("waiting", .pending), job("paused", .paused), job("done", .completed),
        ])
        var services = AppServices.preview()
        services.jobQueue = jobs
        let queue = QueueModel(services: services)
        let observing = Task { await queue.run() }
        defer { observing.cancel() }
        #expect(await eventually { !queue.isLoading })
        await queue.clearQueue()
        #expect(queue.jobs.isEmpty)
        #expect(await jobs.jobs().isEmpty)
        #expect(!queue.isClearing && queue.removingIDs.isEmpty)
    }

    @Test func unsupportedRemovalShowsAnErrorWithoutHidingTheJob() async throws {
        let jobs = InstantlyFailingQueue()
        let id = try await jobs.enqueue(job("failed", .pending))
        var services = AppServices.preview()
        services.jobQueue = jobs
        let queue = QueueModel(services: services)
        let observing = Task { await queue.run() }
        defer { observing.cancel() }
        #expect(await eventually { !queue.isLoading })
        await queue.remove(id)
        #expect(queue.jobs.map(\.id) == [id])
        #expect(queue.errorMessage != nil)
    }

    @Test func groupsJobsByStateInDisplayOrder() async {  // FILE-AC-14
        let services = AppServices.preview(jobs: [
            job("a", .failed), job("b", .running, progress: 0.3), job("c", .pending), job("d", .paused),
        ])
        let queue = QueueModel(services: services)
        let task = Task { await queue.run() }
        #expect(await eventually { !queue.isLoading })
        #expect(queue.visibleGroups == [.running, .pending, .paused, .failed])
        #expect(!queue.isLoading)
        task.cancel()
    }

    @Test func eventsUpdateRowsWithoutPolling() async {  // FILE-AC-14
        let jobs = PlaceholderJobQueue(seed: [job("a", .running)])
        var services = AppServices.preview()
        services.jobQueue = jobs
        let queue = QueueModel(services: services)
        let task = Task { await queue.run() }
        #expect(await eventually { !queue.isLoading })  // run() subscribes before it loads
        let first = await jobs.jobs()[0]
        _ = try? await jobs.enqueue(job("late", .pending))
        await jobs.pause(first.id)
        #expect(await eventually { queue.jobs.count == 2 && queue.jobs(in: .paused).count == 1 })
        #expect(queue.jobs.count == 2)
        #expect(queue.jobs(in: .paused).count == 1)
        task.cancel()
    }

    @Test func detailShowsEngineLanguageAndEta() {  // FILE-AC-14
        var running = job("a", .running)
        running.engine = "whisperkit"
        running.etaSeconds = 150
        running.settings.languageMode = .multilingual(["en", "si"])
        #expect(QueueFormatting.detail(for: running) == "whisperkit · EN + SI · about 3 min left")
        #expect(QueueFormatting.eta(20) == "about 20 s left")
        #expect(QueueFormatting.eta(nil) == nil)
        #expect(QueueFormatting.language(.autoDetect) == "Auto")
    }

    @Test func pauseResumeCancelRetryTransitions() async {  // FILE-AC-06
        let seeded = job("a", .running)
        let jobs = PlaceholderJobQueue(seed: [seeded])
        var services = AppServices.preview()
        services.jobQueue = jobs
        let queue = QueueModel(services: services)
        await queue.pause(seeded.id)
        #expect(await jobs.jobs()[0].state == .paused)
        await queue.resume(seeded.id)
        #expect(await jobs.jobs()[0].state == .pending)
        await queue.cancel(seeded.id)
        #expect(await jobs.jobs()[0].state == .cancelled)
        await queue.retry(seeded.id)
        #expect(await jobs.jobs()[0].state == .pending)
    }

    @Test func dragReorderHonouredByQueue() async {  // FILE-AC-07
        let first = job("a", .pending)
        let running = job("r", .running)
        let second = job("b", .pending)
        let third = job("c", .pending)
        let jobs = PlaceholderJobQueue(seed: [first, running, second, third])
        var services = AppServices.preview()
        services.jobQueue = jobs
        let queue = QueueModel(services: services)
        let task = Task { await queue.run() }
        #expect(await eventually { !queue.isLoading })
        await queue.movePending(from: IndexSet(integer: 2), to: 0)  // third pending -> top of the waiting list
        #expect(queue.jobs(in: .pending).map(\.id) == [third.id, first.id, second.id])
        #expect(await jobs.jobs().first?.id == third.id)
        task.cancel()
    }

    @Test func concurrencyIsAppliedClampedAndPersisted() async {  // FILE-AC-07
        let store = InMemorySettingsStore()
        var services = AppServices.preview()
        services.settings = store
        let queue = QueueModel(services: services)
        await queue.setConcurrency(9)
        #expect(queue.maxConcurrency == 4)
        #expect(await store.value(for: SettingsKey.queueMaxConcurrency, as: Int.self) == 4)
        let restored = QueueModel(services: services)
        let task = Task { await restored.run() }
        #expect(await eventually { restored.maxConcurrency == 4 })
        #expect(restored.maxConcurrency == 4)
        task.cancel()
    }

    @Test func failedJobCanBeRetriedWithoutAffectingOthers() async {  // FILE-AC-03
        var failed = job("bad", .failed)
        failed.failureReason = "Unsupported format"
        let ok = job("ok", .pending)
        let jobs = PlaceholderJobQueue(seed: [failed, ok])
        var services = AppServices.preview()
        services.jobQueue = jobs
        let queue = QueueModel(services: services)
        let task = Task { await queue.run() }
        #expect(await eventually { !queue.isLoading })
        #expect(queue.jobs(in: .failed).first?.failureReason == "Unsupported format")
        await queue.retryAllFailed()
        let states = await jobs.jobs().map(\.state)
        #expect(states == [.pending, .pending])
        task.cancel()
    }
}

@Suite @MainActor struct BatchSettingsTests {
    private let english = model("en-only", "English only", languages: ["en"])
    private let multi = model("multi", "Multilingual", languages: ["en", "si", "ta"])
    private let sinhala = model("si-only", "Sinhala tuned", languages: ["si"])

    private func services(installed: Set<ModelID> = [], queue: PlaceholderJobQueue = PlaceholderJobQueue()) -> AppServices {
        var services = AppServices.preview()
        services.models = MockModelManager(descriptors: [english, multi, sinhala], installed: installed)
        services.jobQueue = queue
        return services
    }

    @Test func defaultsToEnglishAutoModel() async {  // FILE-AC-04
        let batch = BatchSettingsModel(urls: [URL(fileURLWithPath: "/tmp/a.m4a")], services: services())
        await batch.prepare()
        #expect(batch.languageMode == .single(.english))
        #expect(batch.modelID == nil)
        #expect(!batch.diarize && batch.translateTo == nil && batch.autoExportPresetID == nil)
    }

    @Test func modelListFollowsChosenLanguages() async {  // FILE-AC-04, ADR-008
        let batch = BatchSettingsModel(urls: [URL(fileURLWithPath: "/tmp/a.m4a")], services: services())
        await batch.prepare()
        #expect(Set(batch.availableModels.map(\.id)) == ["en-only", "multi"])
        batch.setSingleLanguage(.sinhala)
        #expect(Set(batch.availableModels.map(\.id)) == ["si-only", "multi"])
        batch.setKind(.multilingual)  // {en} initially
        batch.toggleLanguage(.sinhala)
        #expect(Set(batch.availableModels.map(\.id)) == ["multi"])
        batch.setKind(.autoDetect)
        #expect(Set(batch.availableModels.map(\.id)) == ["multi"])
    }

    @Test func changingLanguageResetsUncoveredModelToAuto() async {
        let batch = BatchSettingsModel(urls: [URL(fileURLWithPath: "/tmp/a.m4a")], services: services(installed: ["en-only"]))
        await batch.prepare()
        await batch.selectModel("en-only")
        #expect(batch.modelID == "en-only")
        batch.setSingleLanguage(.sinhala)
        #expect(batch.modelID == nil)
    }

    @Test func pickingUndownloadedModelDownloadsInline() async {  // FILE-AC-05
        let batch = BatchSettingsModel(urls: [URL(fileURLWithPath: "/tmp/a.m4a")], services: services())
        await batch.prepare()
        #expect(!batch.isInstalled("multi"))
        await batch.selectModel("multi")
        #expect(batch.isInstalled("multi"))
        #expect(batch.download == .idle)
        #expect(batch.modelID == "multi")
    }

    @Test func submitEnqueuesFilesAndFoldersWithBatchSettings() async {  // FILE-AC-01, FILE-AC-02, FILE-AC-04
        let queue = PlaceholderJobQueue()
        let batch = BatchSettingsModel(
            urls: [URL(fileURLWithPath: "/tmp/a.m4a"), URL(fileURLWithPath: "/tmp/folder", isDirectory: true)],
            services: services(queue: queue))
        await batch.prepare()
        batch.diarize = true
        batch.translateTo = .english
        batch.setSingleLanguage(.sinhala)
        let preset = PresetID()
        batch.autoExportPresetID = preset
        #expect(await batch.submit())
        let jobs = await queue.jobs()
        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.settings.languageMode == .single(.sinhala) && $0.settings.diarize })
        #expect(jobs.allSatisfy { $0.settings.translateTo == .english && $0.settings.autoExportPresetID == preset })
    }

    @Test func duplicatesAreSkippedByDefault() async {  // edge case: duplicate detection
        let url = URL(fileURLWithPath: "/tmp/a.m4a")
        let queue = PlaceholderJobQueue(seed: [Job(kind: .transcribeFile, state: .pending, input: url)])
        let batch = BatchSettingsModel(urls: [url, URL(fileURLWithPath: "/tmp/b.m4a")], services: services(queue: queue))
        await batch.prepare()
        #expect(batch.duplicates == [url])
        #expect(await batch.submit())
        #expect(await queue.jobs().count == 2)
        batch.skipDuplicates = false
        #expect(batch.urlsToEnqueue.count == 2)
    }

    @Test func queueModelPresentsAndSubmitsBatch() async {  // NAV-AC-05, FILE-AC-01
        let queue = PlaceholderJobQueue()
        let queueModel = QueueModel(services: services(queue: queue))
        queueModel.presentBatch(urls: [URL(fileURLWithPath: "/tmp/a.m4a")])
        #expect(queueModel.batch != nil)
        await queueModel.submitBatch()
        #expect(queueModel.batch == nil)
        #expect(await queue.jobs().count == 1)
    }
}

@Suite @MainActor struct HomeTests {
    @Test func dropEnqueuesThroughJobQueue() async {  // NAV-AC-05
        let queue = PlaceholderJobQueue()
        var services = AppServices.preview()
        services.jobQueue = queue
        let home = HomeModel(services: services)
        #expect(await home.enqueue([URL(fileURLWithPath: "/tmp/a.m4a")]))
        #expect(await queue.jobs().count == 1)
        #expect(await home.enqueue([]) == false)
    }

    @Test func activeJobsSummaryFollowsEvents() async {  // NAV-AC-06
        let queue = PlaceholderJobQueue(seed: [job("a", .running, progress: 0.5)])
        var services = AppServices.preview()
        services.jobQueue = queue
        let home = HomeModel(services: services)
        let task = Task { await home.run() }
        #expect(await eventually { home.summary.running == 1 })
        #expect(home.summary.running == 1)
        _ = try? await queue.enqueue(job("b", .pending))
        #expect(await eventually { home.summary.pending == 1 })
        #expect(home.summary.pending == 1)
        #expect(home.activeJobs.count == 2)
        task.cancel()
    }

    @Test func emptyHomeShowsNoRecentAndStatusReflectsModelInstall() async {  // NAV-AC-08
        let descriptor = model("m", "Whisper", languages: ["en"])
        var services = AppServices.preview()
        services.models = MockModelManager(descriptors: [descriptor], installed: [])
        let home = HomeModel(services: services)
        await home.reloadRecent()
        await home.reloadModelStatus()
        #expect(home.recent.isEmpty && !home.isLoadingRecent)
        #expect(home.modelStatus == ModelStatusSummary(name: "Whisper", isInstalled: false, installedCount: 0))
        #expect(await home.ensureDefaultModel())
        #expect(home.modelStatus?.isInstalled == true)
    }
}
