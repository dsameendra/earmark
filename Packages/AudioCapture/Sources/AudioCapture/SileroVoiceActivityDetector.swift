import AppCore
@preconcurrency import CoreML
import Foundation

/// Offline adapter for the pinned Silero unified 256 ms v6.2.1 conversion.
/// The caller supplies an already installed model. No model discovery or download occurs here.
/// State belongs to one analysis call, so re-analysing an open utterance or sharing the detector
/// across capture lanes cannot leak recurrent state between unrelated audio.
public actor SileroVoiceActivityDetector: VoiceActivityDetector {
    public nonisolated static let installedRelativePath = "EarmarkSupport/silero-vad-v6.2.1.mlmodelc"
    private let model: MLModel
    private static let frameSize = 4_096
    private static let contextSize = 64
    private static let stateSize = 128

    public init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let loaded = try MLModel(contentsOf: modelURL, configuration: configuration)
        let inputs = loaded.modelDescription.inputDescriptionsByName
        let outputs = loaded.modelDescription.outputDescriptionsByName
        let schema = ["audio_input": [1, 4_160], "hidden_state": [1, 128], "cell_state": [1, 128]]
        let outputSchema = ["vad_output": [1, 1, 1], "new_hidden_state": [1, 128], "new_cell_state": [1, 128]]
        for (name, shape) in schema {
            guard inputs[name]?.multiArrayConstraint?.shape.map(\.intValue) == shape,
                  inputs[name]?.multiArrayConstraint?.dataType == .float32 else {
                throw AppError.unsupportedFormat("The installed speech detector has an incompatible input: \(name).")
            }
        }
        for (name, shape) in outputSchema {
            guard outputs[name]?.multiArrayConstraint?.shape.map(\.intValue) == shape,
                  outputs[name]?.multiArrayConstraint?.dataType == .float32 else {
                throw AppError.unsupportedFormat("The installed speech detector has an incompatible output: \(name).")
            }
        }
        self.model = loaded
    }

    public func speechRanges(in chunk: AudioChunk) throws -> [TimeRange] {
        guard !chunk.samples.isEmpty else { return [] }
        guard chunk.samples.count <= Int(AudioChunk.sampleRate * 120), chunk.samples.allSatisfy(\.isFinite) else {
            throw AppError.unsupportedFormat("Speech detection requires finite audio in windows of at most 120 seconds.")
        }
        let audio = try MLMultiArray(shape: [1, 4_160], dataType: .float32)
        let hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        let cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for i in 0..<Self.stateSize { hidden[i] = 0; cell[i] = 0 }
        var context = [Float](repeating: 0, count: Self.contextSize)
        var probabilities: [Float] = []
        for start in stride(from: 0, to: chunk.samples.count, by: Self.frameSize) {
            try Task.checkCancellation()
            let end = min(chunk.samples.count, start + Self.frameSize)
            let actual = Array(chunk.samples[start..<end])
            let frame = actual + [Float](repeating: actual.last ?? 0, count: Self.frameSize - actual.count)
            let probability: Float = try autoreleasepool {
                for i in 0..<Self.contextSize { audio[i] = NSNumber(value: context[i]) }
                for i in 0..<Self.frameSize { audio[i + Self.contextSize] = NSNumber(value: frame[i]) }
                let input = try MLDictionaryFeatureProvider(dictionary: ["audio_input": audio, "hidden_state": hidden, "cell_state": cell])
                let output = try model.prediction(from: input)
                guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue,
                      let nextHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
                      let nextCell = output.featureValue(for: "new_cell_state")?.multiArrayValue else {
                    throw AppError.engineFailure("silero-vad", reason: "The speech detector returned incomplete state.")
                }
                for i in 0..<Self.stateSize { hidden[i] = nextHidden[i]; cell[i] = nextCell[i] }
                let value = probability[0].floatValue
                guard value.isFinite, (0...1).contains(value) else {
                    throw AppError.engineFailure("silero-vad", reason: "The speech detector returned an invalid probability.")
                }
                return value
            }
            probabilities.append(probability)
            context = Array(frame.suffix(Self.contextSize))
        }
        return Self.ranges(probabilities: probabilities, samples: chunk.samples.count)
    }

    static func ranges(probabilities: [Float], samples: Int) -> [TimeRange] {
        let step = Double(frameSize) / AudioChunk.sampleRate
        let duration = Double(samples) / AudioChunk.sampleRate
        var start: Double?
        var quiet: Double?
        var result: [TimeRange] = []
        func finish(_ end: Double) {
            if let start, end - start >= 0.25 {
                let range = TimeRange(start: max(0, start - 0.15), end: min(duration, end + 0.15))
                if let last = result.last, range.start <= last.end {
                    result[result.count - 1] = TimeRange(start: last.start, end: max(last.end, range.end))
                } else { result.append(range) }
            }
        }
        for (index, probability) in probabilities.enumerated() {
            let time = Double(index) * step
            if probability >= 0.5 {
                if start == nil { start = time }
                quiet = nil
            } else if probability < 0.35, start != nil {
                if quiet == nil { quiet = time }
                if let silenceStart = quiet, time + step - silenceStart >= 0.5 {
                    finish(silenceStart)
                    start = nil
                    quiet = nil
                }
            }
        }
        finish(quiet ?? duration)
        return result
    }
}
