import Foundation
import SpeechNative
import Testing

@Suite("Native speech wire boundaries")
struct SpeechWireTests {
    private func pcm(_ samples: [Float]) -> Data {
        var data = Data()
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func acceptsLittleEndianUnalignedFiniteAudio() throws {
        let data = pcm([-1, -0.25, 0, 0.25, 1])
        #expect(try SpeechWire.decodePCM(data, maximumSamples: 5) == [-1, -0.25, 0, 0.25, 1])
    }

    @Test func rejectsOversizedNonfiniteAndMalformedAudio() {
        for data in [Data(), Data([0, 0, 0]), pcm([.nan]), pcm([.infinity]), pcm([1.01]), pcm([0, 0])] {
            #expect(throws: SpeechWireError.self) { try SpeechWire.decodePCM(data, maximumSamples: 1) }
        }
    }

    @Test func commandRoundTripPreservesAudioAndDirection() throws {
        let request = SpeechWorkerRequest(id: 42, operation: .run, pcm: pcm([0.25]), language: "de", targetLanguage: "en", diarize: true)
        let decoded = try JSONDecoder().decode(SpeechWorkerRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.id == 42 && decoded.operation == .run)
        #expect(decoded.language == "de" && decoded.targetLanguage == "en" && decoded.diarize == true)
        #expect(try SpeechWire.decodePCM(#require(decoded.pcm), maximumSamples: 1) == [0.25])
    }

    @Test func unknownOperationCannotBeAcceptedAsTranscription() {
        let bytes = Data(#"{"id":1,"operation":"execute-code"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SpeechWorkerRequest.self, from: bytes) }
    }
}

@Suite("Incremental native speech framing")
struct SpeechLineFramerTests {
    @Test func preservesSplitUTF8AndMultipleCompleteMessages() throws {
        let first = Data(#"{"text":"සිංහල 日本語"}"#.utf8)
        let second = Data(#"{"id":2}"#.utf8)
        let source = first + Data([10]) + second + Data([10])
        var framer = SpeechLineFramer()
        var frames: [Data] = []
        for byte in source { frames += try framer.append(Data([byte])) }
        #expect(frames == [first, second])
        #expect(!framer.hasPartialMessage)
        _ = try framer.append(Data("partial".utf8))
        #expect(framer.hasPartialMessage)
    }

    @Test func refusesUnterminatedOversizeAndMessageFloods() throws {
        var framer = SpeechLineFramer()
        #expect(throws: SpeechWireError.invalid("Oversized speech response.")) {
            try framer.append(Data(repeating: 1, count: SpeechWire.maximumMessageBytes + 1))
        }
        var flood = SpeechLineFramer()
        #expect(throws: SpeechWireError.self) { try flood.append(Data(String(repeating: "1\n", count: 33).utf8)) }
        var empty = SpeechLineFramer()
        #expect(throws: SpeechWireError.self) { try empty.append(Data([10])) }
    }
}
