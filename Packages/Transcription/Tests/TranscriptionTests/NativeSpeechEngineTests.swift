import AppCore
import Foundation
import SpeechNative
import Testing
@testable import Transcription

private func snapshot(committed: String, tentative: String = "", audioMS: Int64 = 0, inputMS: Int64 = 0) -> SpeechNativeSnapshot {
    SpeechNativeSnapshot(
        timestampKind: .token, text: committed, committedText: committed, tentativeText: tentative, language: nil, revision: 1,
        isFinal: false, inputReceivedMS: inputMS, audioCommittedMS: audioMS, bufferedMS: 0, committedSegments: 0,
        committedWords: 0, segments: [], words: [], speakerTurns: [])
}

@Suite("Native speech stream emission")
struct NativeSpeechEngineTests {
    @Test("unterminated text stays a partial and never invents word times")
    func partial() {
        var emitter = NativeSpeechEngine.StreamEmitter(language: "en")
        let events = emitter.events(snapshot(committed: "hello there", tentative: "how", audioMS: 1500), final: false)
        guard case .partial(let partial) = events.first, events.count == 1 else { Issue.record("expected one partial"); return }
        #expect(partial.text == "hello there how")
        #expect(partial.start == 0)
    }

    @Test("a sentence end finalizes only the new text and later text starts a new segment")
    func sentenceFinal() {
        var emitter = NativeSpeechEngine.StreamEmitter(language: "en")
        var events = emitter.events(snapshot(committed: "It works. ", audioMS: 2000), final: false)
        guard case .final(let first) = events.first else { Issue.record("expected a final"); return }
        #expect(first.text == "It works." && first.start == 0 && first.end == 2 && first.words.isEmpty)
        events = emitter.events(snapshot(committed: "It works. Next one", audioMS: 3500), final: false)
        guard case .partial(let next) = events.first else { Issue.record("expected a partial"); return }
        #expect(next.text == "Next one" && next.start == 2)
    }

    @Test("long unpunctuated speech is cut after ten seconds, and the end flushes everything including tentative text")
    func timeCutAndFlush() {
        var emitter = NativeSpeechEngine.StreamEmitter(language: "de")
        let text = "eins zwei drei vier fünf sechs sieben acht neun zehn"
        var events = emitter.events(snapshot(committed: text, audioMS: 10_500), final: false)
        guard case .final(let cut) = events.first else { Issue.record("expected a time cut"); return }
        #expect(cut.text == text && cut.languageCode == "de")
        events = emitter.events(snapshot(committed: text + " elf", tentative: "zwölf", audioMS: 11_000, inputMS: 11_200), final: true)
        guard case .final(let tail) = events.first, events.count == 1 else { Issue.record("expected the flush"); return }
        #expect(tail.text == "elf zwölf" && tail.start >= 10.5)
    }

    @Test("model identities map only to their own finite profiles and languages")
    func bindings() {
        #expect(NativeSpeechEngine.languages(for: NativeSpeechEngine.nemotronModel).contains("hi"))
        #expect(!NativeSpeechEngine.languages(for: NativeSpeechEngine.nemotronModel).contains("si"))
        #expect(NativeSpeechEngine.languages(for: NativeSpeechEngine.canaryModel).contains("lv"))
        #expect(NativeSpeechEngine.languages(for: "other/model").isEmpty)
    }
}
