import AppCore
import FeatureSupport
import Foundation
import Processing
import SwiftUI
import Testing

@testable import FeatureEditor

@Suite struct EditorLogicTests {
    // MARK: Word re-alignment (EDIT-AC-06)

    @Test func editKeepsUnchangedWordTimings() {
        let segment = Fixtures.segment("hello big world", start: 10)
        let edited = SegmentOps.editText(segment, to: "hello huge world")
        #expect(edited.text == "hello huge world")
        #expect(edited.words.map(\.text) == ["hello", "huge", "world"])
        #expect(edited.words[0] == segment.words[0])
        #expect(edited.words[2] == segment.words[2])
        #expect(edited.words[1].start == 11 && edited.words[1].end == 12)
        #expect(edited.start == segment.start && edited.end == segment.end)
    }

    @Test func editGrowingTextInterpolatesInsideTheOriginalSpan() {
        let segment = Fixtures.segment("hello big world", start: 0)
        let edited = SegmentOps.editText(segment, to: "hello very big bad world")
        #expect(edited.words.map(\.text) == ["hello", "very", "big", "bad", "world"])
        #expect(SegmentOps.isMonotonic(edited))
        #expect(edited.words[0] == segment.words[0])
        #expect(edited.words[4] == segment.words[2])
        #expect(edited.words[1].start >= 1 && edited.words[3].end <= 2.0001)
    }

    @Test func editShrinkingAndSinhalaStayMonotonic() {
        let segment = Fixtures.segment("ශ්‍රී ලංකාව සහ English mixed", start: 0, language: "si")
        let edited = SegmentOps.editText(segment, to: "ශ්‍රී ලංකාව English")
        #expect(edited.text == "ශ්‍රී ලංකාව English")
        #expect(SegmentOps.isMonotonic(edited))
        #expect(edited.words.first == segment.words.first)
        #expect(edited.end == segment.end)
    }

    @Test func editWithoutChangeIsNoOpAndWordlessSegmentStaysWordless() {
        let segment = Fixtures.segment("same text", start: 0)
        #expect(SegmentOps.editText(segment, to: "same text") == segment)
        var plain = segment
        plain.words = []
        #expect(SegmentOps.editText(plain, to: "other text").words.isEmpty)
    }

    // MARK: Split / merge (EDIT-AC-07)

    @Test func splitPartitionsWordsAndKeepsSpeakerAndLanguage() throws {
        var segment = Fixtures.segment("one two three four", start: 5, speaker: Fixtures.alice.id, language: "si")
        segment.translations = [SegmentTranslation(language: "en", text: "x", engine: "e")]
        let (first, second) = try #require(SegmentOps.split(segment, beforeWord: 2))
        #expect(first.text == "one two" && second.text == "three four")
        #expect(first.id == segment.id && second.id != segment.id)
        #expect(first.words.count == 2 && second.words.count == 2)
        #expect(first.speakerID == segment.speakerID && second.speakerID == segment.speakerID)
        #expect(first.languageCode == "si" && second.languageCode == "si")
        #expect(first.end <= second.start)
        #expect(first.start == segment.start && second.end == segment.end)
        #expect(SegmentOps.isMonotonic(first) && SegmentOps.isMonotonic(second))
        #expect(SegmentOps.split(segment, beforeWord: 0) == nil)
        #expect(SegmentOps.split(segment, beforeWord: 4) == nil)
    }

    @Test func splitAtCharacterOffsetSnapsToWord() throws {
        let segment = Fixtures.segment("alpha beta gamma", start: 0)
        let (first, second) = try #require(SegmentOps.split(segment, atCharacterOffset: 7))
        #expect(first.text == "alpha beta" && second.text == "gamma")
    }

    @Test func splitSegmentWithoutWordsUsesProportionalTokens() throws {
        var segment = Fixtures.segment("a b c d", start: 0)
        segment.words = []
        let (first, second) = try #require(SegmentOps.split(segment, beforeWord: 1))
        #expect(first.text == "a" && second.text == "b c d")
        #expect(second.start >= first.end)
    }

    @Test func mergeConcatenatesAndStaysMonotonic() {
        var a = Fixtures.segment("one two", start: 0, speaker: Fixtures.alice.id, language: "en")
        var b = Fixtures.segment("three four five", start: 2, speaker: Fixtures.bob.id, language: "si")
        a.confidence = 0.8
        b.confidence = 0.6
        let merged = SegmentOps.merge(a, b)
        #expect(merged.text == "one two three four five")
        #expect(merged.words.count == 5)
        #expect(merged.id == a.id && merged.speakerID == a.speakerID)
        #expect(merged.languageCode == "si")  // the longer segment wins
        #expect(merged.start == 0 && merged.end == 5)
        #expect(SegmentOps.isMonotonic(merged))
        #expect(abs((merged.confidence ?? 0) - 0.7) < 1e-9)
    }

    @Test func mergeOfOverlappingWordsClampsToMonotonic() {
        let a = Fixtures.segment("one two", start: 0)
        var b = Fixtures.segment("three", start: 1)  // overlaps a's last word
        b.start = 1
        let merged = SegmentOps.merge(a, b)
        #expect(SegmentOps.isMonotonic(merged))
    }

    // MARK: Timeline / click-to-seek mapping (EDIT-AC-02)

    @Test func timelineLocatesWordsByBinarySearch() {
        let segments = Fixtures.segments()
        let timeline = WordTimeline(segments: segments)
        #expect(timeline.locate(0.2) == WordRef(segmentID: segments[0].id, wordIndex: 0))
        #expect(timeline.locate(1.5) == WordRef(segmentID: segments[0].id, wordIndex: 1))
        #expect(timeline.locate(2.99) == WordRef(segmentID: segments[0].id, wordIndex: 2))
        #expect(timeline.locate(4.6) == WordRef(segmentID: segments[1].id, wordIndex: 1))
        #expect(timeline.locate(100) == nil)
    }

    @Test func timelineGapsBeforeFirstAndHolding() {
        var segments = Fixtures.segments()
        segments[0].start = 1
        segments[0].words = segments[0].words.map {
            var w = $0
            w.start += 1
            w.end += 1
            return w
        }
        segments[0].end = 4
        let timeline = WordTimeline(segments: segments)
        #expect(timeline.locate(0.5) == nil)
        #expect(timeline.locate(8.7) == nil)  // gap between segments
        #expect(timeline.locate(8.7, holdInGaps: true)?.segmentID == segments[1].id)
        #expect(timeline.locate(8.7, holdInGaps: true)?.wordIndex == nil)
        #expect(timeline.locate(0.5, holdInGaps: true) == nil)
    }

    @Test func timelineHandlesOverlappingSegments() {
        let long = Segment(start: 0, end: 20, text: "long", words: [Word(text: "long", start: 0, end: 20)])
        let short = Segment(start: 5, end: 6, text: "short", words: [Word(text: "short", start: 5, end: 6)])
        let timeline = WordTimeline(segments: [long, short])
        #expect(timeline.locate(5.5)?.segmentID == short.id)
        #expect(timeline.locate(10)?.segmentID == long.id)  // walks back past the short one
    }

    @Test func lastIndexBinarySearchEdges() {
        let values: [TimeInterval] = [0, 1, 2, 2, 5]
        #expect(WordTimeline.lastIndex(atOrBefore: -1, in: values) == nil)
        #expect(WordTimeline.lastIndex(atOrBefore: 0, in: values) == 0)
        #expect(WordTimeline.lastIndex(atOrBefore: 2, in: values) == 3)
        #expect(WordTimeline.lastIndex(atOrBefore: 4.9, in: values) == 3)
        #expect(WordTimeline.lastIndex(atOrBefore: 99, in: values) == 4)
        #expect(WordTimeline.lastIndex(atOrBefore: 1, in: []) == nil)
    }

    @Test func timelineScalesToTenThousandSegments() {
        let segments = (0..<10_000).map { Fixtures.segment("a b c d", start: Double($0) * 5) }
        let timeline = WordTimeline(segments: segments)
        let clock = ContinuousClock()
        var hits = 0
        let elapsed = clock.measure {
            for i in 0..<10_000 where timeline.locate(Double(i) * 5 + 1.5)?.wordIndex == 1 { hits += 1 }
        }
        #expect(hits == 10_000)
        #expect(elapsed < .milliseconds(500))
    }

    @Test func seekTargetIsWordStartOrSegmentStart() {
        let segment = Fixtures.segment("a b c", start: 10)
        #expect(SeekTarget.time(for: segment, wordIndex: 2) == 12)
        #expect(SeekTarget.time(for: segment, wordIndex: nil) == 10)
        #expect(SeekTarget.time(for: segment, wordIndex: 99) == 10)
    }

    @Test func findOverTenThousandSegmentsStaysResponsiveInDebugBuilds() throws {  // FR-AC-09
        let segments = (0..<10_000).map { Fixtures.segment("the quick brown fox number \($0) jumps over the lazy dog", start: Double($0)) }
        let query = FindQuery(text: "fox", matchCase: false, wholeWord: true)
        _ = FindReplaceModel.search(query, in: segments)  // warm up
        let clock = ContinuousClock()
        var outcome = FindOutcome()
        let elapsed = clock.measure { outcome = FindReplaceModel.search(query, in: segments) }
        print("FIND_10K_MS", elapsed)
        #expect(outcome.matches.count == 10_000)
        #expect(elapsed < .milliseconds(400))  // unoptimised debug build; ~100 ms measured
    }

    // MARK: Undo / redo (EDIT-AC-12)

    @MainActor @Test func everyEditKindUndoesAndRedoesExactly() async throws {
        let (model, _) = await Fixtures.model()
        let original = model.segments
        let originalSpeakers = model.speakers
        let id = original[0].id

        model.editText(id, to: "hello there world")
        model.setSpeaker(Fixtures.bob.id, for: [id])
        model.setLanguage("si", for: [id])
        #expect(model.split(id, beforeWord: 1))
        #expect(model.merge(original[1].id, withNext: true))
        model.setIgnored(true, for: [model.segments[1].id])
        model.renameSpeaker(Fixtures.alice.id, to: "Alicia")
        let final = model.segments
        let finalSpeakers = model.speakers
        #expect(final != original)

        var steps = 0
        while model.canUndo {
            model.undo()
            steps += 1
        }
        #expect(steps == 7, "undid \(steps)")
        #expect(model.segments == original)
        #expect(model.speakers == originalSpeakers)
        while model.canRedo { model.redo() }
        #expect(model.segments == final)
        #expect(model.speakers == finalSpeakers)
    }

    @MainActor @Test func undoActionNamesDescribeTheEdit() async {
        let (model, _) = await Fixtures.model()
        model.editText(model.segments[0].id, to: "changed")
        #expect(model.undoActionName == "Edit Text")
        model.undo()
        #expect(model.redoActionName == "Edit Text")
        #expect(!model.canUndo && model.canRedo)
    }

    @MainActor @Test func splitThenUndoRestoresSingleSegmentAtSameIndex() async {
        let (model, _) = await Fixtures.model()
        let original = model.segments
        #expect(model.split(original[1].id, beforeWord: 2))
        #expect(model.segments.count == 4)
        #expect(model.segments[1].id == original[1].id && model.segments[2].start >= model.segments[1].end)
        model.undo()
        #expect(model.segments == original)
    }

    // MARK: Persistence (EDIT-AC-18)

    @MainActor @Test func editsPersistIncrementallyAndStructuralEditsRewrite() async {
        let (model, repo) = await Fixtures.model()
        let id = model.segments[0].id
        model.editText(id, to: "persisted text")
        await model.flush()
        #expect(await repo.upsertCalls >= 1)
        #expect(await repo.replaceCalls == 0)
        #expect(await repo.stored[model.transcriptID]?.first?.text == "persisted text")
        model.split(id, beforeWord: 1)
        await model.flush()
        #expect(await repo.replaceCalls == 1)
        #expect(await repo.stored[model.transcriptID]?.count == 4)
        model.undo()
        await model.flush()
        #expect(await repo.stored[model.transcriptID]?.count == 3)
    }

    @MainActor @Test func speakerChangesSaveTheHeader() async {
        let (model, repo) = await Fixtures.model()
        model.renameSpeaker(Fixtures.alice.id, to: "Alicia")
        await model.flush()
        #expect(await repo.headers[model.transcriptID]?.speakers.first?.name == "Alicia")
    }

    @MainActor @Test func typingNeverWaitsForPersistence() async {
        let (model, _) = await Fixtures.model(persistDelay: .seconds(30))
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<50 { model.editText(model.segments[0].id, to: "typing \(i)") }
        }
        #expect(elapsed < .milliseconds(500))  // 50 edits, none waiting on the repository
        #expect(model.segments[0].text == "typing 49")
        await model.flush()
    }

    // MARK: Speakers (EDIT-AC-08)

    @MainActor @Test func renameMergeAndColourSpeakers() async {
        let (model, _) = await Fixtures.model()
        model.renameSpeaker(Fixtures.bob.id, to: "Robert")
        #expect(model.speaker(Fixtures.bob.id)?.name == "Robert")
        model.setSpeakerColor(Fixtures.bob.id, hex: "#112233")
        #expect(model.speaker(Fixtures.bob.id)?.colorHex == "#112233")
        model.mergeSpeaker(Fixtures.bob.id, into: Fixtures.alice.id)
        #expect(model.speakers.map(\.id) == [Fixtures.alice.id])
        #expect(model.segments.allSatisfy { $0.speakerID == Fixtures.alice.id })
        model.undo()
        #expect(model.speakers.count == 2)
        #expect(model.segments.contains { $0.speakerID == Fixtures.bob.id })
        let added = model.addSpeaker(named: "Carol")
        #expect(added != nil && model.speakers.count == 3)
        model.setSpeaker(added, for: [model.segments[0].id])
        #expect(model.segments[0].speakerID == added)
    }

    @MainActor @Test func languageChangeAppliesToSelection() async {
        let (model, _) = await Fixtures.model()
        let ids = Set(model.segments.prefix(2).map(\.id))
        model.setLanguage("si", for: ids)
        #expect(model.segments.prefix(2).allSatisfy { $0.languageCode == "si" })
        #expect(model.segments[2].languageCode == "en")
        #expect(model.languageChoices.contains("si"))
    }

    // MARK: Ignored (EDIT-AC-10)

    @MainActor @Test func showIgnoredTogglesVisibility() async {
        var segments = Fixtures.segments()
        segments[1].isIgnored = true
        let (model, _) = await Fixtures.model(segments: segments)
        #expect(model.visibleSegments.count == 2 && model.hiddenIgnoredCount == 1)
        model.setShowIgnored(true)
        #expect(model.visibleSegments.count == 3)
        model.setIgnored(false, for: [segments[1].id])
        #expect(!model.segment(segments[1].id)!.isIgnored)
    }

    @MainActor @Test func handIgnoringMarksTheFlagManualSoRulesNeverOverrideIt() async {  // IGN-AC-05, IGN-AC-07
        let segments = Fixtures.segments()
        let (model, _) = await Fixtures.model(segments: segments)
        #expect(!model.segment(segments[0].id)!.ignoreFlagIsManual)
        model.setIgnored(true, for: [segments[0].id])
        #expect(model.segment(segments[0].id)!.isIgnored && model.segment(segments[0].id)!.ignoreFlagIsManual)
        model.undo()
        #expect(!model.segment(segments[0].id)!.isIgnored && !model.segment(segments[0].id)!.ignoreFlagIsManual)
    }

    // MARK: Paragraphs

    @Test func paragraphsGroupConsecutiveSameSpeakerWithinGap() {
        let a = Fixtures.segment("one two", start: 0, speaker: Fixtures.alice.id)
        let b = Fixtures.segment("three", start: 2.5, speaker: Fixtures.alice.id)
        let c = Fixtures.segment("four", start: 3.5, speaker: Fixtures.bob.id)
        let d = Fixtures.segment("five", start: 30, speaker: Fixtures.bob.id)
        let paragraphs = ParagraphBuilder.make(from: [a, b, c, d])
        #expect(paragraphs.map { $0.segments.count } == [2, 1, 1])
    }

    // MARK: View options (EDIT-AC-14)

    @MainActor @Test func globalDefaultsAndPerTranscriptOverrideArePersisted() async {
        let settings = InMemorySettingsStore()
        let (first, _) = await Fixtures.model(settings: settings)
        first.updateOptions { $0.fontSize = 20 }
        first.setCustomizesThisTranscript(true)
        first.updateOptions {
            $0.fontSize = 26
            $0.layout = .paragraphs
        }
        #expect(first.options.fontSize == 26 && first.globalOptions.fontSize == 20)
        await first.flush()

        let transcript = first.transcript!
        let repo = FakeTranscriptRepository(transcript: transcript, segments: first.segments)
        let reopened = TranscriptEditorModel(
            transcriptID: transcript.id, repository: repo, settings: settings, engineFactory: { _ in nil })
        await reopened.load()
        #expect(reopened.options.fontSize == 26 && reopened.options.layout == .paragraphs)
        #expect(reopened.globalOptions.fontSize == 20 && reopened.globalOptions.layout == .segments)
        #expect(reopened.customizesThisTranscript)

        let other = Transcript(title: "Other", source: .file)
        let otherModel = TranscriptEditorModel(
            transcriptID: other.id, repository: FakeTranscriptRepository(transcript: other, segments: []), settings: settings,
            engineFactory: { _ in nil })
        await otherModel.load()
        #expect(otherModel.options.fontSize == 20 && !otherModel.customizesThisTranscript)

        reopened.setCustomizesThisTranscript(false)
        #expect(reopened.options.fontSize == 20)
    }

    @MainActor @Test func optionValuesAreClamped() async {
        let (model, _) = await Fixtures.model()
        model.updateOptions {
            $0.fontSize = 500
            $0.lineSpacing = -3
        }
        #expect(model.options.fontSize == ViewOptions.fontSizeRange.upperBound)
        #expect(model.options.lineSpacing == 0)
    }

    @Test func overrideDifferenceOnlyHoldsChangedFields() {
        var effective = ViewOptions()
        effective.showTimestamps = false
        let diff = ViewOptionsOverride.difference(from: ViewOptions(), to: effective)
        #expect(diff.showTimestamps == false && diff.fontSize == nil && diff.layout == nil)
        #expect(diff.applied(to: ViewOptions()) == effective)
    }

    // MARK: Bookmarks & highlights (EDIT-AC-13)

    @MainActor @Test func bookmarksAndHighlightsPersistWithNotes() async {
        let settings = InMemorySettingsStore()
        let (model, repo) = await Fixtures.model(settings: settings)
        model.playback.seek(to: 4)
        let bookmark = model.addBookmark(note: "important")
        model.updateBookmark(bookmark.id, note: "very important")
        let highlight = model.addHighlight(segmentID: model.segments[1].id, wordRange: 1...2, note: "quote")
        await model.flush()
        #expect(await repo.savedBookmarks[bookmark.id]?.note == "very important")
        #expect(await repo.savedBookmarks[bookmark.id]?.time == 4)
        #expect(model.highlights(in: model.segments[1].id).count == 1)
        #expect(highlight?.time == model.segments[1].words[1].start)
        let stored = await settings.value(for: EditorSettingsKey.highlights(model.transcriptID), as: [TextHighlight].self)
        #expect(stored?.first?.note == "quote")
        model.removeBookmark(bookmark.id)
        await model.flush()
        #expect(model.bookmarks.isEmpty)
        #expect(await repo.savedBookmarks[bookmark.id]?.deletedAt != nil)
    }

    // MARK: Find / replace integration (EDIT-AC-11, FR-AC-01...06)

    @MainActor @Test func findHighlightsAndStepsThroughMatches() async {
        let (model, _) = await Fixtures.model()
        let find = FindReplaceModel(editor: model)
        find.open()
        find.text = "is"
        await find.searchNow()
        #expect(find.matches.count == 2)  // "this", "is"
        #expect(find.statusText == "1 of 2")
        find.next()
        #expect(find.statusText == "2 of 2")
        find.next()
        #expect(find.statusText == "1 of 2")
        find.previous()
        #expect(find.statusText == "2 of 2")
        find.wholeWord = true
        await find.searchNow()
        #expect(find.matches.count == 1)
        find.matchCase = true
        find.text = "IS"
        await find.searchNow()
        #expect(find.matches.isEmpty && find.statusText == "No results")
    }

    @MainActor @Test func invalidRegexShowsInlineErrorAndSearchesNothing() async {
        let (model, _) = await Fixtures.model()
        let find = FindReplaceModel(editor: model)
        find.open()
        find.isRegex = true
        find.text = "(unclosed"
        await find.searchNow()
        #expect(find.errorMessage != nil && find.matches.isEmpty)
        #expect(!find.canReplace)
    }

    @MainActor @Test func scopeRestrictsMatches() async {
        let (model, _) = await Fixtures.model()
        let find = FindReplaceModel(editor: model)
        find.open()
        find.text = "e"
        find.scope = .speaker(Fixtures.bob.id)
        await find.searchNow()
        #expect(Set(find.matches.map(\.segmentID)) == [model.segments[1].id])
        model.selection = [model.segments[2].id]
        find.scope = .selection
        await find.searchNow()
        #expect(Set(find.matches.map(\.segmentID)) == [model.segments[2].id])
    }

    @MainActor @Test func ignoredSegmentsAreSearchedOnlyWhenShown() async {
        var segments = Fixtures.segments()
        segments[1].isIgnored = true
        let (model, _) = await Fixtures.model(segments: segments)
        let find = FindReplaceModel(editor: model)
        find.open()
        find.text = "second"
        await find.searchNow()
        #expect(find.matches.isEmpty)
        model.setShowIgnored(true)
        await find.searchNow()
        #expect(find.matches.count == 1)
    }

    @MainActor @Test func debouncedSearchRunsOffMainAndUpdates() async {
        let (model, _) = await Fixtures.model()
        let find = FindReplaceModel(editor: model)
        find.open()
        find.text = "segment"
        #expect(find.matches.isEmpty)  // not yet: debounced
        await find.waitForSearch()
        #expect(find.matches.count == 1)
        #expect(find.matchedWords[model.segments[1].id] == [4])
    }

    @MainActor @Test func replaceAllShowsPreviewThenAppliesAsOneUndoStep() async {
        let (model, _) = await Fixtures.model()
        let original = model.segments
        let find = FindReplaceModel(editor: model)
        find.open(replace: true)
        find.text = "a"
        find.wholeWord = true
        find.replacement = "the"
        await find.searchNow()
        await find.requestReplaceAll()
        #expect(find.preview?.count == 1)
        #expect(find.preview?.first?.before == "and a third one here")
        #expect(find.preview?.first?.after == "and the third one here")
        #expect(model.segments == original)  // nothing applied before confirm
        await find.confirmReplaceAll()
        #expect(model.segments[2].text == "and the third one here")
        #expect(SegmentOps.isMonotonic(model.segments[2]))
        #expect(model.segments[2].start == original[2].start && model.segments[2].end == original[2].end)
        model.undo()
        #expect(model.segments == original)  // one step restores everything
        #expect(!model.canUndo)
    }

    @MainActor @Test func replaceCurrentReplacesOneAndAdvances() async {
        let (model, _) = await Fixtures.model()
        let find = FindReplaceModel(editor: model)
        find.open(replace: true)
        find.text = "is"
        find.replacement = "was"
        await find.searchNow()
        #expect(find.matches.count == 2)
        await find.replaceCurrent()
        #expect(find.matches.count == 1)
        #expect(model.segments[1].text == "thwas is the second segment")
        model.undo()
        #expect(model.segments[1].text == "this is the second segment")
    }

    @MainActor @Test func readOnlyTranscriptKeepsFindButDisablesReplace() async {
        let (model, _) = await Fixtures.model()
        model.setReadOnly(true)
        let find = FindReplaceModel(editor: model)
        find.open(replace: true)
        find.text = "is"
        await find.searchNow()
        #expect(!find.matches.isEmpty && !find.canReplace)
        model.editText(model.segments[0].id, to: "blocked")
        #expect(model.segments[0].text == "hello big world")
    }

    // MARK: Playback model (EDIT-AC-03...05)

    @MainActor @Test func clickingAWordSeeksToItsStartAndDoubleClickPlays() async {
        let (model, _) = await Fixtures.model()
        let player = FakePlayer()
        model.playback.attach(player, isVideo: false)
        let segment = model.segments[1]
        await model.playback.seekToWord(in: segment, wordIndex: 2).value
        #expect(player.seeks == [segment.words[2].start])
        #expect(model.playback.currentTime == segment.words[2].start)
        #expect(!player.isPlaying)
        await model.playback.playFrom(segment).value
        #expect(player.seeks.last == segment.start && player.isPlaying)
    }

    @MainActor @Test func karaokeHighlightFollowsTicksAndOnlyChangesWhenWordChanges() async {
        let (model, _) = await Fixtures.model()
        let player = FakePlayer()
        model.playback.attach(player, isVideo: false)
        let segments = model.segments
        player.onTick?(4.7)
        #expect(model.playback.activeRef == WordRef(segmentID: segments[1].id, wordIndex: 1))
        player.onTick?(4.9)
        #expect(model.playback.activeRef?.wordIndex == 1)
        player.onTick?(8.7)  // gap
        #expect(model.playback.activeRef == nil)
        #expect(model.playback.scrollTargetID == segments[1].id)
    }

    @MainActor @Test func autoScrollPausesOnManualScrollAndReturns() async {
        let (model, _) = await Fixtures.model()
        let player = FakePlayer()
        model.playback.attach(player, isVideo: false)
        player.onTick?(0.5)
        let before = model.playback.scrollRequest
        player.onTick?(4.0)
        #expect(model.playback.scrollRequest > before)  // following
        model.playback.userDidScroll()
        #expect(!model.playback.autoFollow && model.playback.showsReturnToPlayhead)
        let paused = model.playback.scrollRequest
        player.onTick?(9.5)
        #expect(model.playback.scrollRequest == paused)  // no auto-scroll while paused
        model.playback.returnToPlayhead()
        #expect(model.playback.autoFollow && !model.playback.showsReturnToPlayhead)
        #expect(model.playback.scrollRequest > paused)
    }

    @MainActor @Test func speedIsClampedAndSkipsMoveRelative() async {
        let (model, _) = await Fixtures.model()
        let player = FakePlayer()
        model.playback.attach(player, isVideo: false)
        model.playback.setSpeed(10)
        #expect(model.playback.speed == 3 && player.speed == 3)
        model.playback.setSpeed(0.1)
        #expect(model.playback.speed == 0.5)
        await model.playback.seek(to: 20).value
        model.playback.skip(by: -15)
        #expect(model.playback.currentTime == 5)
        model.playback.skip(by: 15)
        #expect(model.playback.currentTime == 20)
        model.playback.skip(by: -100)
        #expect(model.playback.currentTime == 0)
    }

    @Test func shortcutsMapSpaceJKLAndArrows() {
        #expect(PlaybackShortcut.resolve(key: .space, modifiers: []) == .togglePlay)
        #expect(PlaybackShortcut.resolve(key: KeyEquivalent("k"), modifiers: []) == .togglePlay)
        #expect(PlaybackShortcut.resolve(key: KeyEquivalent("j"), modifiers: []) == .skip(-5))
        #expect(PlaybackShortcut.resolve(key: KeyEquivalent("l"), modifiers: []) == .skip(5))
        #expect(PlaybackShortcut.resolve(key: .leftArrow, modifiers: []) == .skip(-5))
        #expect(PlaybackShortcut.resolve(key: .rightArrow, modifiers: .option) == .skip(15))
        #expect(PlaybackShortcut.resolve(key: KeyEquivalent("l"), modifiers: .shift) == .skip(15))
        #expect(PlaybackShortcut.resolve(key: KeyEquivalent("l"), modifiers: .command) == nil)
        #expect(PlaybackShortcut.resolve(key: KeyEquivalent("x"), modifiers: []) == nil)
        #expect(PlaybackSpeed.steps.first == 0.5 && PlaybackSpeed.steps.last == 3)
    }

    @MainActor @Test func missingMediaDisablesPlaybackButKeepsTextEditable() async {
        let (model, _) = await Fixtures.model()
        #expect(model.playback.mediaState == .missing && !model.playback.canPlay)
        model.editText(model.segments[0].id, to: "still editable")
        #expect(model.segments[0].text == "still editable")
        model.playback.togglePlay()  // must not crash
    }

    // MARK: Waveform & scrubber (EDIT-AC-16)

    @Test func waveformReducesToPeakBins() {
        let peaks = WaveformPeaks.reduce(samples: [0.1, -0.5, 0.2, 0.9, -0.3, 0.0, 0.4, 0.4], bins: 4)
        #expect(peaks == [0.5, 0.9, 0.3, 0.4])
        #expect(WaveformPeaks.reduce(samples: [], bins: 4).isEmpty)
    }

    @Test func speakerRegionsCoalesceNearbySameSpeakerSegments() {
        let a = Fixtures.segment("a b", start: 0, speaker: Fixtures.alice.id)
        let b = Fixtures.segment("c d", start: 2.5, speaker: Fixtures.alice.id)
        let c = Fixtures.segment("e", start: 5, speaker: Fixtures.bob.id)
        let regions = SpeakerRegions.make(from: [a, b, c])
        #expect(regions.count == 2 && regions[0].end == 4.5 && regions[1].speakerID == Fixtures.bob.id)
    }

    // MARK: Export (EDIT-AC export sheet)

    @MainActor @Test func copyAsTextAndMarkdownUsesExportService() async {
        let (model, _) = await Fixtures.model()
        var copied: [String] = []
        let box = CopyBox()
        let export = EditorExportModel(editor: model, copyToPasteboard: { box.values.append($0) })
        export.options.includeSpeakers = true
        await export.copy(markdown: false)
        await export.copy(markdown: true)
        copied = box.values
        #expect(copied.count == 2)
        #expect(copied[0].contains("hello big world") && copied[0].contains("Alice"))
        #expect(export.statusMessage == "Copied as Markdown")
    }

    @MainActor @Test func exportWritesChosenFormatAndSharesTempFile() async throws {
        let (model, _) = await Fixtures.model()
        let export = EditorExportModel(editor: model, copyToPasteboard: { _ in })
        export.options.format = .srt
        let url = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString).srt")
        await export.export(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("-->") && text.contains("hello"))
        try FileManager.default.removeItem(at: url)
        let share = await export.prepareShareFile()
        #expect(share != nil && share!.pathExtension == "srt")
    }

    @MainActor @Test func invalidExportOptionsSurfaceAReadableError() async {
        let (model, _) = await Fixtures.model()
        let export = EditorExportModel(editor: model, copyToPasteboard: { _ in })
        export.options.translation = .replace  // no language chosen
        let url = FileManager.default.temporaryDirectory.appending(path: "bad-\(UUID().uuidString).txt")
        await export.export(to: url)
        #expect(export.errorMessage?.contains("translation") == true)
    }
}

@MainActor final class CopyBox { var values: [String] = [] }
