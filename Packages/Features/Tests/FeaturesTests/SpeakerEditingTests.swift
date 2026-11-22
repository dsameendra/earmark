import AppCore
import FeatureSettings
import FeatureSupport
import Foundation
import Testing

@testable import FeatureEditor

struct FakeEmbeddings: SpeakerEmbeddingProvider {
    var failure: AppError?
    func embedding(file: URL, range: TimeRange) async throws -> SpeakerEmbedding {
        if let failure { throw failure }
        return SpeakerEmbedding(vector: [Float(range.start), Float(range.end), 1])
    }
}

@Suite @MainActor struct SpeakerEditingTests {
    // MARK: Word-level reassign (DIA-AC-11)

    @Test func middleWordsSplitIntoThreeSegmentsAsOneUndoStep() async {
        let (model, _) = await Fixtures.model()
        let original = model.segments
        let target = original[0]  // "hello big world", Alice
        #expect(model.reassignWords(in: target.id, wordRange: 1..<2, to: Fixtures.bob.id))
        #expect(model.segments.count == original.count + 2)
        let pieces = Array(model.segments.prefix(3))
        #expect(pieces.map(\.text) == ["hello", "big", "world"])
        #expect(pieces.map(\.speakerID) == [Fixtures.alice.id, Fixtures.bob.id, Fixtures.alice.id])
        #expect(pieces[0].id == target.id)
        #expect(pieces[0].end <= pieces[1].start && pieces[1].end <= pieces[2].start)
        model.undo()
        #expect(model.segments == original)  // exact restore
        model.redo()
        #expect(model.segments.prefix(3).map(\.text) == ["hello", "big", "world"])
    }

    @Test func leadingAndTrailingRangesSplitIntoTwo() async {
        let (model, _) = await Fixtures.model()
        let id = model.segments[0].id
        #expect(model.reassignWords(in: id, wordRange: 0..<1, to: Fixtures.bob.id))
        #expect(model.segments.prefix(2).map(\.text) == ["hello", "big world"])
        #expect(model.segments.prefix(2).map(\.speakerID) == [Fixtures.bob.id, Fixtures.alice.id])
        model.undo()
        #expect(model.segments.count == 3 && model.segments[0].text == "hello big world")
        #expect(model.reassignWords(in: id, wordRange: 2..<3, to: Fixtures.bob.id))
        #expect(model.segments.prefix(2).map(\.text) == ["hello big", "world"])
    }

    @Test func coveringTheWholeSegmentJustChangesItsSpeaker() async {
        let (model, _) = await Fixtures.model()
        let count = model.segments.count
        #expect(model.reassignWords(in: model.segments[0].id, wordRange: 0..<3, to: Fixtures.bob.id))
        #expect(model.segments.count == count && model.segments[0].speakerID == Fixtures.bob.id)
    }

    @Test func noOpReassignChangesNothing() async {
        let (model, _) = await Fixtures.model()
        #expect(!model.reassignWords(in: model.segments[0].id, wordRange: 0..<1, to: Fixtures.alice.id))
        #expect(!model.reassignWords(in: model.segments[0].id, wordRange: 2..<2, to: Fixtures.bob.id))
        #expect(!model.reassignWords(in: SegmentID(), wordRange: 0..<1, to: Fixtures.bob.id))
        #expect(!model.canUndo)
    }

    @Test func reassignFromPlayheadTakesTheTailOfTheSegment() async {
        let (model, _) = await Fixtures.model()
        let id = model.segments[0].id  // words at 0, 1, 2
        #expect(!model.playheadIsInside(id) == true || model.playback.currentTime == 0)
        model.playback.seek(to: 1.5)
        #expect(model.playheadIsInside(id))
        #expect(model.reassignWordsFromPlayhead(in: id, to: Fixtures.bob.id))
        #expect(model.segments.prefix(2).map(\.text) == ["hello big", "world"])
        #expect(model.segments[1].speakerID == Fixtures.bob.id)
    }

    @Test func reassignPersistsTheSplit() async {
        let (model, repo) = await Fixtures.model()
        model.reassignWords(in: model.segments[0].id, wordRange: 1..<2, to: Fixtures.bob.id)
        await model.flush()
        #expect(await repo.stored[model.transcriptID]?.count == 5)
    }

    // MARK: Existing operations the UI drives (DIA-AC-09, 10)

    @Test func renameAndMergeUpdateSegmentsAndSpeakers() async {
        let (model, _) = await Fixtures.model()
        model.renameSpeaker(Fixtures.alice.id, to: "Dana")
        #expect(model.speaker(model.segments[0].speakerID)?.name == "Dana")
        model.mergeSpeaker(Fixtures.bob.id, into: Fixtures.alice.id)
        #expect(model.speakers.count == 1)
        #expect(model.segments.allSatisfy { $0.speakerID == Fixtures.alice.id })
    }

    // MARK: Reconciliation (DIA-AC-06)

    @Test func reportListsOnlySegmentsWhoseSpeakerChanged() {
        let a = Fixtures.segment("one two", start: 0, speaker: Fixtures.alice.id)
        let b = Fixtures.segment("three four", start: 5, speaker: Fixtures.alice.id)
        var finalB = b
        finalB.speakerID = Fixtures.bob.id
        let newcomer = Fixtures.segment("five", start: 9, speaker: Fixtures.bob.id)
        let report = ReconciliationReport.make(live: [a, b], final: [a, finalB, newcomer])
        #expect(report.relabeledSegmentIDs == [b.id])
        #expect(report.totalSegments == 3 && !report.acknowledged)
        #expect(ReconciliationReport.make(live: [a], final: [a]).isEmpty)
    }

    @Test func relabelIsFlaggedOnceThenNeverAgain() async {
        let store = InMemorySettingsStore()
        let transcript = Fixtures.transcript()
        let segments = Fixtures.segments()
        let report = ReconciliationReport(relabeledSegmentIDs: [segments[1].id], totalSegments: 3)
        await store.set(report, for: SettingsKey.speakerReconciliation(transcript.id.description))

        let (first, _) = await Fixtures.model(segments: segments, transcript: transcript, settings: store)
        #expect(first.reconciliation == report)
        #expect(first.relabeledSegmentIDs == [segments[1].id])
        first.acknowledgeReconciliation()
        #expect(first.reconciliation == nil && first.relabeledSegmentIDs.isEmpty)
        await first.flush()

        let (second, _) = await Fixtures.model(segments: segments, transcript: transcript, settings: store)  // reopened
        #expect(second.reconciliation == nil)
    }

    @Test func emptyOrAcknowledgedReportsShowNothing() async {
        let store = InMemorySettingsStore()
        let transcript = Fixtures.transcript()
        await store.set(
            ReconciliationReport(relabeledSegmentIDs: [], totalSegments: 3), for: SettingsKey.speakerReconciliation(transcript.id.description))
        let (model, _) = await Fixtures.model(transcript: transcript, settings: store)
        #expect(model.reconciliation == nil)
    }

    // MARK: Voice profiles (DIA-AC-13)

    @Test func savingAVoiceProfileStoresOnlyEmbeddingAndNameAndLinksTheSpeaker() async {
        let (model, _) = await Fixtures.model()
        let repository = InMemoryVoiceProfiles()
        model.voiceProfiles = repository
        model.embeddings = FakeEmbeddings()
        model.mediaURL = URL(fileURLWithPath: "/tmp/meeting.m4a")
        #expect(model.canSaveVoiceProfiles)
        #expect(await model.saveVoiceProfile(for: Fixtures.alice.id))
        let stored = try? await repository.profiles()
        #expect(stored?.count == 1 && stored?.first?.name == "Alice" && stored?.first?.embedding.vector.count == 3)
        #expect(model.speaker(Fixtures.alice.id)?.voiceProfileID == stored?.first?.id)
        model.undo()  // the link is one undo step
        #expect(model.speaker(Fixtures.alice.id)?.voiceProfileID == nil)
    }

    @Test func deletingAVoiceProfileRemovesItAndUnlinks() async {
        let (model, _) = await Fixtures.model()
        let repository = InMemoryVoiceProfiles()
        model.voiceProfiles = repository
        model.embeddings = FakeEmbeddings()
        model.mediaURL = URL(fileURLWithPath: "/tmp/meeting.m4a")
        await model.saveVoiceProfile(for: Fixtures.alice.id)
        #expect(await model.removeVoiceProfile(for: Fixtures.alice.id))
        #expect((try? await repository.profiles())?.isEmpty == true)
        #expect(model.speaker(Fixtures.alice.id)?.voiceProfileID == nil)
    }

    @Test func savingNeedsMediaAndAReportedFailureIsShown() async {
        let (model, _) = await Fixtures.model()
        model.voiceProfiles = InMemoryVoiceProfiles()
        model.embeddings = FakeEmbeddings(failure: .cancelled)
        #expect(!model.canSaveVoiceProfiles)  // no media yet
        model.mediaURL = URL(fileURLWithPath: "/tmp/meeting.m4a")
        #expect(!(await model.saveVoiceProfile(for: Fixtures.alice.id)))
        #expect(model.voiceProfileError != nil)
    }

    @Test func settingsModelListsRenamesAndDeletesProfiles() async {
        let older = VoiceProfile(name: "Sam", embedding: SpeakerEmbedding(vector: [1]), createdAt: Date(timeIntervalSince1970: 100))
        let newer = VoiceProfile(name: "Priya", embedding: SpeakerEmbedding(vector: [2]), createdAt: Date(timeIntervalSince1970: 200))
        let model = VoiceProfilesModel(repository: InMemoryVoiceProfiles(items: [older, newer]))
        await model.load()
        #expect(model.isAvailable && model.profiles.map(\.name) == ["Priya", "Sam"])
        await model.rename(older.id, to: "  Samantha ")
        #expect(model.profiles.map(\.name) == ["Priya", "Samantha"])
        await model.delete(newer.id)  // DIA-AC-13 deletion
        #expect(model.profiles.map(\.name) == ["Samantha"])
        #expect(!VoiceProfilesModel(repository: nil).isAvailable)
    }
}
