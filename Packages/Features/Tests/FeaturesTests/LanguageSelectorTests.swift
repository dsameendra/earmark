import AppCore
import AppKit
import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import FeatureSupport

@Suite("Language selector") @MainActor struct LanguageSelectorTests {
    static let codes: [LanguageCode] = ["en", "es", "fr", "de", "si", "ta", "ja"].map { LanguageCode($0) }

    private func selector(
        recents: [LanguageCode] = [], suggested: [LanguageCode] = [], reasons: [LanguageCode: String] = [:]
    ) -> LanguageSelectorModel {
        LanguageSelectorModel(options: Self.codes, recents: recents, suggested: suggested, unsupportedReasons: reasons)
    }

    @Test func withoutSearchRecentAndSuggestedComeFirstWithoutDuplicates() {
        let model = selector(recents: ["fr", "en", "xx"], suggested: ["en", "es"])
        let sections = model.sections()
        #expect(sections.map(\.kind) == [.recent, .suggested, .other])
        #expect(sections[0].codes == ["fr", "en"], "recents keep their order and drop languages that are not offered")
        #expect(sections[1].codes == ["es"], "a recent language is not repeated under Suggested")
        #expect(Set(sections.flatMap(\.codes)) == Set(Self.codes))
        #expect(sections.flatMap(\.codes).count == Self.codes.count, "every language appears exactly once")
    }

    @Test func withNothingToHighlightOneAlphabeticalSection() {
        let sections = selector().sections()
        #expect(sections.count == 1 && sections[0].kind == .all && sections[0].title == "All languages")
        let names = sections[0].codes.map(LanguageSelectorModel.name(of:))
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func topSectionsAreCapped() {
        let many = LanguageSelectorModel(options: Self.codes, recents: Self.codes, topLimit: 3)
        #expect(many.sections()[0].codes.count == 3)
    }

    @Test func searchFiltersByNameNativeNameAndCodeIgnoringCaseAndAccents() {
        let model = selector(recents: ["fr"])
        #expect(model.visibleCodes(query: "ger").contains("de"))
        #expect(model.visibleCodes(query: "GER") == model.visibleCodes(query: "ger"))
        #expect(model.visibleCodes(query: "  es ").contains("es"), "surrounding space is ignored, and codes match")
        #expect(model.visibleCodes(query: "espanol").contains("es"), "native names match without accents")
        #expect(model.visibleCodes(query: "zzzz").isEmpty)
        #expect(model.sections(query: "zzzz").isEmpty)
        let results = model.sections(query: "an")
        #expect(results.count == 1 && results[0].kind == .results, "a search collapses to one Results section")
    }

    @Test func emptyOrBlankQueryShowsEverything() {
        #expect(selector().visibleCodes(query: "   ").count == Self.codes.count)
    }

    @Test func toggleAddsAndRemoves() {
        var chosen: Set<LanguageCode> = []
        chosen = LanguageSelectorModel.toggled("en", in: chosen)
        chosen = LanguageSelectorModel.toggled("si", in: chosen)
        #expect(chosen == ["en", "si"])
        chosen = LanguageSelectorModel.toggled("en", in: chosen)
        #expect(chosen == ["si"])
    }

    @Test func chipsAndSummaryDescribeTheChoice() {
        let model = selector()
        #expect(model.summary(for: []) == "No languages chosen")
        #expect(model.summary(for: ["en"]) == LanguageSelectorModel.name(of: "en"))
        #expect(model.summary(for: ["en", "fr"]).contains(" and "))
        #expect(model.summary(for: ["en", "fr", "de", "es"]).hasSuffix("and 2 more"))
        #expect(model.chips(for: ["fr", "en"]).count == 2)
    }

    @Test func unsupportedLanguagesAreGreyedWithAReasonButChosenOnesCanStillBeRemoved() {
        let model = selector(reasons: ["si": "Whisper does not support it."])
        #expect(!model.isSupported("si") && model.reason(for: "si") != nil)
        #expect(model.isSupported("en") && model.reason(for: "en") == nil)
        #expect(!model.isSelectable("si", selection: ["en"]))
        #expect(model.isSelectable("si", selection: ["si"]), "a chosen language that became unsupported can be removed")
    }

    @Test func reasonsComeFromTheChosenModelsLanguages() {
        let whisper = ModelDescriptor(
            id: "w", displayName: "Whisper", kind: .asr, runtime: .coreML, languages: ["en", "es"], sizeBytes: 1,
            license: LicenseInfo(spdx: "MIT"))
        let reasons = LanguageSelectorModel.unsupportedReasons(for: whisper, options: Self.codes)
        #expect(reasons["en"] == nil && reasons["es"] == nil)
        #expect(reasons["si"]?.contains("Whisper") == true && reasons["fr"] != nil)
        #expect(LanguageSelectorModel.unsupportedReasons(for: nil, options: Self.codes).isEmpty, "Automatic allows every language")
    }

    @Test func suggestionsFollowThePreferredLanguagesThatAreOffered() {
        let got = LanguageSelectorModel.suggestions(from: Self.codes, preferred: ["fr-FR", "xx-XX", "en-US", "fr-CA"])
        #expect(got == ["fr", "en"])
    }

    @Test func arrowKeysWalkTheVisibleRowsAndSkipUnavailableOnes() {
        let model = selector(recents: ["fr"], reasons: ["es": "no"])
        let order = model.visibleCodes().filter { $0 != "es" }
        #expect(model.step(from: nil, by: 1) == order.first)
        #expect(model.step(from: nil, by: -1) == order.last)
        #expect(model.step(from: order[0], by: 1) == order[1])
        #expect(model.step(from: order[0], by: -1) == order[0], "stops at the top")
        #expect(model.step(from: order.last, by: 1) == order.last, "stops at the bottom")
        #expect(selector().step(from: nil, by: 1, query: "zzzz") == nil)
    }

    // MARK: Rendering

    private func render<V: View>(_ view: V, name: String) async -> NSImage? {
        await RenderGate.ready.value
        let renderer = ImageRenderer(content: view.frame(width: 420).padding(16).background(Color.white))
        renderer.scale = 2
        let image = renderer.nsImage
        if let dir = ProcessInfo.processInfo.environment["EARMARK_RENDER_DIR"], let tiff = image?.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return image
    }

    @Test func selectorRendersWithChipsSectionsAndGreyedRows() async throws {
        let model = selector(
            recents: ["fr", "en"], suggested: ["es"], reasons: ["si": "Whisper does not support it. Choose Automatic to use it."])
        let image = try #require(
            await render(
                LanguageMultiSelectView(selector: model, selection: ["en", "fr"], onToggle: { _ in }, onClear: {}, scrolls: false),
                name: "language-selector"))
        #expect(image.size.width > 300 && image.size.height > 280, "the list is roomy, not a sliver: \(image.size)")
        let searched = try #require(
            await render(
                LanguageMultiSelectView(selector: model, selection: [], onToggle: { _ in }, scrolls: false, initialQuery: "zzzz"),
                name: "language-selector-empty"))
        #expect(searched.size.height > 280)
    }
}
