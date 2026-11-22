import AppCore
import FeatureSupport
import Foundation

// MARK: - Languages, re-transcription (EDIT-AC-09, LANG-AC-06/07/08) and translation view (TRN-AC-03..10)

/// What the row draws for a segment's translation in the current mode.
public struct SegmentTranslationDisplay: Equatable, Sendable {
    public var text: String
    public var language: LanguageCode
    public var isLowConfidence: Bool
    public var isStale: Bool
}

extension TranscriptEditorModel {
    func loadLanguageState() async {
        translationChoice =
            await settings.value(for: EditorSettingsKey.translationView(transcriptID), as: TranslationDisplayChoice.self)
            ?? TranslationDisplayChoice()
        revisions = await settings.value(for: EditorSettingsKey.segmentRevisions(transcriptID), as: [SegmentRevision].self) ?? []
        // A saved view of a language that has no translations any more falls back to the original.
        if translationChoice.mode != .original, let target = translationChoice.target, !translationLanguages.contains(target) {
            translationChoice = TranslationDisplayChoice()
        }
    }

    // MARK: Uncertain languages

    /// LANG-AC-06: a guessed language in a multilingual transcript (no confidence, or below the threshold).
    public func isLanguageUncertain(_ segment: Segment) -> Bool {
        LanguageCertainty.isUncertain(segment, in: transcript?.languages ?? [])
    }

    /// Number of segments whose language is uncertain (shown in the toolbar when not zero).
    public var uncertainLanguageCount: Int { segments.filter { isLanguageUncertain($0) && !$0.isIgnored }.count }

    // MARK: Re-transcription

    public var canRetranscribe: Bool { retranscriber != nil && mediaURL != nil && !isReadOnly }

    /// Re-runs ASR for this segment's time range with `language` (EDIT-AC-09). The previous text is kept as a
    /// revision (LANG-AC-08) and the replacement is one undo step.
    public func retranscribe(_ id: SegmentID, as language: LanguageCode) async {
        languageError = nil
        guard let retranscriber, let mediaURL, let old = segment(id), !retranscribing.contains(id) else { return }
        retranscribing.insert(id)
        defer { retranscribing.remove(id) }
        do {
            var new = try await retranscriber.retranscribe(segment: old, mediaURL: mediaURL, language: language)
            guard segment(id) != nil else { return }
            new.translations = []  // they no longer match the text
            if new.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                languageError = "No speech was found in this segment when read as \(Self.name(of: language))."
                return
            }
            await record(SegmentRevision(segmentID: id, text: old.text, languageCode: old.languageCode))
            perform(EditDelta(name: "Re-transcribe Segment", replaced: [.init(before: old, after: new)]))
        } catch {
            languageError = Self.describe(error, language: language)
        }
    }

    public func dismissLanguageError() { languageError = nil }

    public func revisions(for id: SegmentID) -> [SegmentRevision] { revisions.filter { $0.segmentID == id } }

    private func record(_ revision: SegmentRevision) async {
        revisions.append(revision)
        saveSetting(revisions, for: EditorSettingsKey.segmentRevisions(transcriptID))
    }

    static func name(of code: LanguageCode) -> String { Locale.current.localizedString(forLanguageCode: code.rawValue) ?? code.rawValue }

    static func describe(_ error: any Error, language: LanguageCode) -> String {
        switch error as? AppError {
        case .modelNotInstalled:
            return "The speech model for \(name(of: language)) is not downloaded yet. Download it in Settings > Models, then try again."
        case .unsupportedLanguage: return "No speech model supports \(name(of: language))."
        case .cancelled: return "Re-transcription was cancelled."
        default: return "Re-transcription failed: \(error.localizedDescription)"
        }
    }

    // MARK: Translation view (TRN-AC-08)

    /// Target languages that have at least one translated segment.
    public var translationLanguages: [LanguageCode] {
        var seen = Set<LanguageCode>()
        for segment in segments { for t in segment.translations { seen.insert(t.language) } }
        return seen.sorted()
    }

    public var canTranslate: Bool { translationService != nil && jobQueue != nil && !isReadOnly }

    public func setTranslationMode(_ mode: TranslationDisplayMode) {
        var choice = translationChoice
        choice.mode = mode
        if mode != .original, choice.target == nil { choice.target = translationLanguages.first }
        translationChoice = choice
        saveSetting(choice, for: EditorSettingsKey.translationView(transcriptID))
    }

    public func setTranslationTarget(_ language: LanguageCode) {
        translationChoice.target = language
        saveSetting(translationChoice, for: EditorSettingsKey.translationView(transcriptID))
    }

    /// The translation to draw under (bilingual) or instead of (translated) the original, or `nil` in original mode.
    public func translationDisplay(for segment: Segment) -> SegmentTranslationDisplay? {
        guard translationChoice.mode != .original, let target = translationChoice.target,
            let translation = segment.translations.first(where: { $0.language.primary == target.primary })
        else { return nil }
        return SegmentTranslationDisplay(
            text: translation.text, language: target,
            isLowConfidence: TranslationConfidence.isLow(engine: translation.engine, target: target),
            isStale: staleTranslations.contains(segment.id))
    }

    /// `true` when the mode wants a translation for this segment but it has none yet.
    public func isMissingTranslation(_ segment: Segment) -> Bool {
        guard translationChoice.mode != .original, let target = translationChoice.target, !segment.isIgnored,
            !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return !segment.translations.contains { $0.language.primary == target.primary }
    }

    public var hasStaleTranslations: Bool { !staleTranslations.isEmpty }

    // MARK: Translate action (TRN-AC-03, TRN-AC-05)

    /// The transcript's source language for the readiness check: its only language, else the first segment language.
    public var translationSource: LanguageCode? {
        if let only = transcript?.languages, only.count == 1 { return only.first }
        return segments.compactMap(\.languageCode).first
    }

    /// Queues a `.translate` job for this transcript and follows it; the finished translations show in the editor.
    public func translate(to target: LanguageCode) async {
        translationStatus = nil
        guard let jobQueue else { return }
        if let source = translationSource, let service = translationService {
            switch await service.readiness(source: source, target: target) {
            case .ready: break
            case .needsModel(let model):
                translationStatus = "The translation model \(model.rawValue) must be downloaded first."
                return
            case .needsApplePack:
                translationStatus = "The language pack must be installed first."
                return
            case .unavailable(let reason):
                translationStatus = reason
                return
            }
        }
        let job = Job(kind: .translate, transcriptID: transcriptID, settings: JobSettings(translateTo: target))
        do {
            let id = try await jobQueue.enqueue(job)
            translationJob = job
            translationChoice.target = target
            watchTranslationJob(id, target: target)
        } catch {
            translationStatus = "Could not start the translation: \(error.localizedDescription)"
        }
    }

    func watchTranslationJob(_ id: JobID, target: LanguageCode) {
        translationWatcher?.cancel()
        guard let jobQueue else { return }
        let events = jobQueue.events()
        translationWatcher = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                guard case .updated(let job) = event, job.id == id else { continue }
                await self.translationJobUpdated(job, target: target)
                if [.completed, .failed, .cancelled].contains(job.state) { return }
            }
        }
    }

    func translationJobUpdated(_ job: Job, target: LanguageCode) async {
        translationJob = job
        switch job.state {
        case .completed:
            await reloadSegmentsFromRepository()
            staleTranslations = []
            translationChoice.target = target
            if translationChoice.mode == .original { translationChoice.mode = .bilingual }
            saveSetting(translationChoice, for: EditorSettingsKey.translationView(transcriptID))
            translationStatus = nil
        case .failed:
            await reloadSegmentsFromRepository()  // partial results are kept (TRN-AC-13)
            translationStatus = job.failureReason ?? "Translation failed."
        case .cancelled:
            await reloadSegmentsFromRepository()
            translationStatus = "Translation cancelled."
        default: break
        }
    }

    public func cancelTranslation() async {
        guard let job = translationJob else { return }
        await jobQueue?.cancel(job.id)
    }

    public var isTranslating: Bool {
        guard let state = translationJob?.state else { return false }
        return state == .pending || state == .running
    }
}
