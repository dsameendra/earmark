import AppCore
import FeatureSupport
import Foundation
import SwiftUI
import Testing

@testable import FeatureEditor

/// Original / Translated / Bilingual must behave the same in the Segments and Paragraphs layouts.
@Suite @MainActor struct TranslationViewModeTests {
    /// Three segments by two speakers; only the first and third have a German translation, the second has none.
    private func partiallyTranslated() async -> (TranscriptEditorModel, [Segment]) {
        var segments = Fixtures.segments()
        segments[0].translations = [SegmentTranslation(language: "de", text: "Hallo große Welt", engine: "apple.translation")]
        segments[2].translations = [SegmentTranslation(language: "de", text: "und ein dritter hier", engine: "apple.translation")]
        let (model, _) = await Fixtures.model(segments: segments)
        return (model, model.segments)
    }

    @Test func everyModeHasOnePresentationPerSegment() async {
        let (model, segs) = await partiallyTranslated()
        #expect(model.presentation(for: segs[0]) == .original)
        model.setTranslationMode(.translated)
        if case .translated(let d) = model.presentation(for: segs[0]) { #expect(d.text == "Hallo große Welt") } else { Issue.record("translated") }
        #expect(model.presentation(for: segs[1]) == .untranslated(isPending: false))
        model.setTranslationMode(.bilingual)
        if case .bilingual = model.presentation(for: segs[2]) {} else { Issue.record("bilingual") }
        #expect(model.presentation(for: segs[1]) == .untranslated(isPending: false))
    }

    @Test func ignoredAndEmptySegmentsAreNotFlaggedUntranslated() async {
        var segments = Fixtures.segments()
        segments[1].isIgnored = true
        segments[0].translations = [SegmentTranslation(language: "de", text: "x", engine: "e")]
        let (model, _) = await Fixtures.model(segments: segments)
        model.setTranslationMode(.translated)
        #expect(model.presentation(for: model.segments[1]) == .original)
    }

    @Test func copyMatchesTheVisibleMode() async {
        let (model, segs) = await partiallyTranslated()
        let all = Set(segs.map(\.id))
        #expect(model.displayedText(for: all).hasPrefix("hello big world\nthis is"))
        model.setTranslationMode(.translated)
        #expect(model.displayedText(for: all) == "Hallo große Welt\nthis is the second segment\nund ein dritter hier")
        model.setTranslationMode(.bilingual)
        #expect(model.displayedText(for: [segs[0].id]) == "hello big world\nHallo große Welt")
    }

    @Test func gutterShowsTheTargetLanguageOnlyWhenTranslated() async {
        let (model, segs) = await partiallyTranslated()
        #expect(model.gutterLanguage(for: [segs[0]]) == "en")
        model.setTranslationMode(.translated)
        #expect(model.gutterLanguage(for: [segs[0]]) == "de")
        #expect(model.gutterLanguage(for: [segs[1]]) == "en")
        model.setTranslationMode(.bilingual)
        #expect(model.gutterLanguage(for: [segs[0]]) == "en")
    }

    @Test func findSearchesWhatIsShownAndReplaceOnlyEditsTheOriginal() async {
        let (model, segs) = await partiallyTranslated()
        let find = FindReplaceModel(editor: model)
        find.open(replace: true)
        // Original mode: "Welt" is not in the visible text.
        find.text = "Welt"
        await find.searchNow()
        #expect(find.matches.isEmpty)
        model.setTranslationMode(.translated)
        await find.searchNow()
        #expect(find.matches.count == 1)
        #expect(find.translationRanges[segs[0].id]?.count == 1)
        #expect(!find.canReplace)  // originals are hidden in Translated mode
        // Untranslated segments are searched in their original text.
        find.text = "second"
        await find.searchNow()
        #expect(find.matches.count == 1 && find.matches[0].field == .text)
        // Bilingual shows both: replace changes the original, never the translation.
        model.setTranslationMode(.bilingual)
        find.text = "o"
        await find.searchNow()
        #expect(find.canReplace)
        find.replacement = "0"
        await find.requestReplaceAll()
        await find.confirmReplaceAll()
        #expect(model.segment(segs[0].id)?.text == "hell0 big w0rld")
        #expect(model.segment(segs[0].id)?.translations.first?.text == "Hallo große Welt")
    }

    @Test func undoingAnEditClearsTheOutOfDateLabel() async {
        let (model, segs) = await partiallyTranslated()
        model.setTranslationMode(.translated)
        model.editText(segs[0].id, to: "hello small world")
        #expect(model.staleTranslations == [segs[0].id])
        model.undo()
        #expect(model.staleTranslations.isEmpty)
        model.redo()
        #expect(model.staleTranslations == [segs[0].id])
    }

    @Test func replaceMarksTranslationsOutOfDate() async {
        let (model, segs) = await partiallyTranslated()
        let find = FindReplaceModel(editor: model)
        find.open(replace: true)
        find.text = "big"
        find.replacement = "tiny"
        await find.searchNow()
        await find.replaceCurrent()
        #expect(model.staleTranslations == [segs[0].id])
    }

    @Test func exportStartsFromTheShownVersion() async {
        let (model, _) = await partiallyTranslated()
        let export = EditorExportModel(editor: model)
        model.setTranslationMode(.bilingual)
        model.updateOptions {
            $0.layout = .paragraphs
            $0.showSpeakers = false
            $0.showTimestamps = false
        }
        export.adoptViewState()
        #expect(export.options.translation == .bilingual && export.options.translationLanguage == "de")
        #expect(!export.options.includeSpeakers && export.options.paragraphGrouping && export.options.timestamps == .none)
        model.setTranslationMode(.original)
        export.adoptViewState()
        #expect(export.options.translation == .none)
    }

    @Test func rtlLanguagesAreDetected() {
        #expect(TextDirection.isRightToLeft("ar") && TextDirection.isRightToLeft("he") && TextDirection.isRightToLeft("fa"))
        #expect(!TextDirection.isRightToLeft("si") && !TextDirection.isRightToLeft("de") && !TextDirection.isRightToLeft(nil))
    }

    // MARK: Rendering

    private func render<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 700, height: 520)) async -> NSImage? {
        await RenderGate.ready.value
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, alignment: .topLeading).fixedSize(horizontal: false, vertical: true).background(
                Color.white))
        renderer.scale = 1
        let image = renderer.nsImage
        if let dir = ProcessInfo.processInfo.environment["EARMARK_RENDER_DIR"], let tiff = image?.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        return image
    }

    private func mixedModel(target: LanguageCode, text: [String]) async -> TranscriptEditorModel {
        var segments = Fixtures.segments()
        segments.append(Fixtures.segment("ශ්‍රී ලංකාව සහ English", start: 15, speaker: Fixtures.bob.id, language: "si"))
        for index in text.indices {
            segments[index].translations = [SegmentTranslation(language: target, text: text[index], engine: "apple.translation")]
        }
        let (model, _) = await Fixtures.model(segments: segments)
        return model
    }

    private func rows(_ model: TranscriptEditorModel, find: FindReplaceModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.options.layout == .paragraphs {
                ForEach(model.paragraphs) { ParagraphRowView(model: model, find: find, paragraph: $0) }
            } else {
                ForEach(model.visibleSegments) { SegmentRowView(model: model, find: find, segment: $0) }
            }
        }
    }

    @Test func everyModeRendersInBothLayoutsWithRightToLeftAndSinhala() async {
        let arabic = await mixedModel(target: "ar", text: ["مرحبا بالعالم الكبير", "هذا هو المقطع الثاني"])
        let sinhala = await mixedModel(target: "si", text: ["ආයුබෝවන් ලොකු ලෝකය", "මෙය දෙවන කොටසයි", "සහ තුන්වන එකක්"])
        for (label, model) in [("ar", arabic), ("si", sinhala)] {
            let find = FindReplaceModel(editor: model)
            for layout in [TranscriptLayoutMode.segments, .paragraphs] {
                for mode in TranslationDisplayMode.allCases {
                    model.updateOptions { $0.layout = layout }
                    model.setTranslationMode(mode)
                    let image = await render(rows(model, find: find), name: "\(label)-\(layout.rawValue)-\(mode.rawValue)")
                    #expect(image != nil && (image?.size.height ?? 0) > 40)
                }
            }
        }
    }

    @Test func mergedParagraphTranslationReadsAsOneBlockWithAGapMarked() async {
        var segments = [
            Fixtures.segment("hello big world", start: 0, speaker: Fixtures.alice.id),
            Fixtures.segment("this is the second one", start: 3.5, speaker: Fixtures.alice.id),
            Fixtures.segment("and a third", start: 7, speaker: Fixtures.alice.id),
        ]
        segments[0].translations = [SegmentTranslation(language: "de", text: "Hallo große Welt", engine: "apple.translation")]
        segments[2].translations = [SegmentTranslation(language: "de", text: "und ein dritter", engine: "apple.translation")]
        let (model, _) = await Fixtures.model(segments: segments)
        model.updateOptions { $0.layout = .paragraphs }
        model.setTranslationMode(.translated)
        #expect(model.paragraphs.count == 1 && model.paragraphs[0].segments.count == 3)
        let find = FindReplaceModel(editor: model)
        let text = ParagraphTranslationText.attributed(
            model.paragraphs[0].segments, model: model, find: find, style: .primary, activeID: nil)
        #expect(String(text.characters) == "Hallo große Welt this is the second one und ein dritter")
        #expect(await render(rows(model, find: find), name: "de-paragraph-merged") != nil)
    }
}
