import AppCore
import AppCoreTesting
import SwiftUI
import Testing

@testable import Dictation

@MainActor
@Suite("HUD")
struct HUDTests {
    @Test func modelLevelsAreClampedAndBounded() {
        let m = DictationHUDModel()
        m.push(level: 2)
        m.push(level: -1)
        m.push(level: 0.5)
        #expect(m.levels.count == DictationHUDModel.barCount)
        #expect(Array(m.levels.suffix(3)) == [1, 0, 0.5])
    }

    @Test func displayTextByPhase() {
        let m = DictationHUDModel()
        m.begin(DictationHUDInfo(hint: "Release Fn to insert"))
        #expect(m.displayText == "Listening…")
        m.partialText = "hello"
        #expect(m.displayText == "hello")
        m.phase = .processing
        #expect(m.phase.systemImage != nil)
        m.phase = .error("Mic unavailable")
        #expect(m.displayText == "Mic unavailable")
    }

    @Test func beginResetsPreviousSession() {
        let m = DictationHUDModel()
        m.partialText = "old"
        m.push(level: 1)
        m.begin(DictationHUDInfo(hint: "h", isExperimental: true))
        #expect(m.partialText.isEmpty && m.isExperimental && m.levels.allSatisfy { $0 == 0 })
    }

    @Test func viewRendersInBothPhases() {
        for phase in [DictationHUDModel.Phase.listening, .processing, .error("x")] {
            let m = DictationHUDModel()
            m.begin(DictationHUDInfo(hint: "Release Fn to insert"))
            m.phase = phase
            let r = ImageRenderer(content: DictationHUDView(model: m))
            #expect(r.cgImage != nil)
        }
    }

    @Test func placementBottomCentreAndCaretAndClamping() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 460, height: 56)
        let bottom = DictationHUDPlacement.frame(size: size, position: .bottomCenter, caret: nil, visibleFrame: screen)
        #expect(bottom.midX == 500 && bottom.minY == DictationHUDPlacement.bottomMargin)
        let caret = CGRect(x: 300, y: 400, width: 2, height: 18)
        let near = DictationHUDPlacement.frame(size: size, position: .nearCursor, caret: caret, visibleFrame: screen)
        #expect(near.maxY <= caret.minY && near.minX == 300)
        // Near the screen bottom the HUD flips above the caret.
        let low = DictationHUDPlacement.frame(size: size, position: .nearCursor, caret: CGRect(x: 300, y: 20, width: 2, height: 18), visibleFrame: screen)
        #expect(low.minY >= 38)
        // Near the right edge it is clamped inside the screen.
        let edge = DictationHUDPlacement.frame(size: size, position: .nearCursor, caret: CGRect(x: 990, y: 400, width: 2, height: 18), visibleFrame: screen)
        #expect(edge.maxX <= screen.maxX)
        // No caret falls back to bottom centre.
        let none = DictationHUDPlacement.frame(size: size, position: .nearCursor, caret: nil, visibleFrame: screen)
        #expect(none == bottom)
    }

    @Test func historyModelSearchesAndClears() async {
        let repo = MemoryHistory()
        let history = DictationHistory(repository: repo)
        await history.record("alpha note", language: nil, settings: DictationSettings())
        await history.record("beta note", language: nil, settings: DictationSettings())
        let model = DictationHistoryModel(history: history)
        await model.reload()
        #expect(model.entries.count == 2)
        model.query = "alpha"
        await model.reload()
        #expect(model.entries.map(\.text) == ["alpha note"])
        await model.clear()
        #expect(model.entries.isEmpty)
    }

    @Test func onboardingContentAndViewRender() {
        let content = AccessibilityOnboardingContent()
        #expect(!content.title.isEmpty && !content.openSettingsTitle.isEmpty)
        let r = ImageRenderer(content: AccessibilityOnboardingView(openSettings: {}, dismiss: {}))
        #expect(r.cgImage != nil)
    }
}
