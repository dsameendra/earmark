import AppCore
import AppCoreTesting
import Export
import FeatureSupport
import Foundation
import Testing

@testable import FeatureEditor

/// Regressions found in the 2026-11-23 editor/playback review.
@Suite("Editor review fixes") @MainActor
struct EditorReviewTests {
    // Find and Replace edits the text, so a later re-transcribe must keep those segments (SCR-013).
    @Test func replaceCurrentAndReplaceAllMarkSegmentsAsUserEdited() async {
        let (model, _) = await Fixtures.model()
        let find = FindReplaceModel(editor: model)
        find.open(replace: true)
        find.text = "hello"
        find.replacement = "howdy"
        await find.searchNow()
        await find.replaceCurrent()
        #expect(model.segments[0].text == "howdy big world" && model.segments[0].isUserEdited)
        #expect(model.segments[1].isUserEdited == false)

        find.text = "second"
        find.replacement = "2nd"
        await find.searchNow()
        await find.requestReplaceAll()
        await find.confirmReplaceAll()
        #expect(model.segments[1].isUserEdited)
        model.undo()
        #expect(model.segments[1].isUserEdited == false, "undo restores the flag with the text")
        model.undo()
        #expect(model.segments[0].isUserEdited == false)
    }

    // Two rapid Start presses must not leave the editor read-only for good.
    @Test func startingARerunTwiceKeepsTheOriginalReadOnlyState() async throws {
        let (model, _) = await Fixtures.model()
        model.jobQueue = PlaceholderJobQueue()
        model.mediaURL = URL(fileURLWithPath: "/tmp/talk.m4a")
        async let first: Void = model.rerun(RerunRequest())
        async let second: Void = model.rerun(RerunRequest())
        _ = await (first, second)
        var job = try #require(model.rerunJob)
        job.state = .completed
        await model.rerunJobUpdated(job)
        #expect(!model.isReadOnly, "the editor is handed back after the job")
    }

    // Pressing play on a finished recording starts it again instead of doing nothing.
    @Test func playAtTheEndRestartsFromTheBeginning() async {
        let playback = PlaybackModel()
        let player = FakePlayer()
        player.duration = 10
        playback.attach(player, isVideo: false)
        await playback.seek(to: 10).value
        playback.togglePlay()
        #expect(playback.currentTime == 0)
        #expect(player.isPlaying)
    }

    // A frame saved on a display that is gone (or on a bigger one) is brought back on screen.
    @Test func savedPlayerFrameIsPulledOntoTheConnectedScreens() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        // Still on a connected screen: untouched.
        let fine = CGRect(x: 1600, y: 100, width: 640, height: 400)
        #expect(PlayerWindowSizing.restored(fine, screens: [main, right]) == fine)
        // The right display was unplugged: moved fully onto the main one.
        let moved = PlayerWindowSizing.restored(fine, screens: [main])
        #expect(moved == CGRect(x: 800, y: 100, width: 640, height: 400))
        // Larger than the screen: shrunk to fit.
        let big = PlayerWindowSizing.restored(CGRect(x: -50, y: -50, width: 3000, height: 2000), screens: [main])
        #expect(big == main)
        #expect(PlayerWindowSizing.restored(fine, screens: []) == nil)
    }

    @Test func suggestedExportNameUsesTheTranscriptTitle() async {
        var transcript = Fixtures.transcript()
        transcript.title = "Weekly sync: Q4/plan"
        let (model, _) = await Fixtures.model(transcript: transcript)
        let export = EditorExportModel(editor: model)
        export.options.format = .markdown
        #expect(export.suggestedFileName == "Weekly sync- Q4-plan.md")
        export.options.format = .srt
        #expect(export.suggestedFileName == "Weekly sync- Q4-plan.srt")
    }

    @Test func rerunStartExplainsWhyItIsDisabled() async {
        let (model, _) = await Fixtures.model()
        let panel = RerunPanelModel(editor: model)
        #expect(panel.startBlockedReason != nil && !panel.canStart, "no media and no queue")
        model.jobQueue = PlaceholderJobQueue()
        model.mediaURL = URL(fileURLWithPath: "/tmp/talk.m4a")
        #expect(panel.startBlockedReason == nil && panel.canStart)
        panel.scope = .selection
        #expect(panel.startBlockedReason?.contains("Select some segments") == true)
        panel.scope = .wholeTranscript
        panel.transcribe = false
        #expect(panel.startBlockedReason?.contains("Choose to re-transcribe") == true)
    }

    // A match in the original must not paint the translation's current match when the offsets coincide.
    @Test func currentTranslationRangeIgnoresOriginalMatches() async {
        var segments = Fixtures.segments()
        segments[0].translations = [SegmentTranslation(language: "de", text: "hallo big welt", engine: "e")]
        let (model, _) = await Fixtures.model(segments: segments)
        model.setTranslationMode(.bilingual)
        let find = FindReplaceModel(editor: model)
        find.open()
        find.text = "hello"
        await find.searchNow()
        #expect(find.currentMatch?.field == .text)
        #expect(find.currentTranslationRange(in: model.segments[0].id) == nil)
        find.text = "welt"
        await find.searchNow()
        #expect(find.currentTranslationRange(in: model.segments[0].id) != nil)
    }
}
