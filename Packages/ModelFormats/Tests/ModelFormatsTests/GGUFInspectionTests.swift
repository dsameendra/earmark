import Foundation
import Testing
@testable import ModelFormats

private func integer<T: FixedWidthInteger>(_ value: T) -> Data {
    var little = value.littleEndian
    return withUnsafeBytes(of: &little) { Data($0) }
}
private func string(_ value: String) -> Data { integer(UInt64(value.utf8.count)) + Data(value.utf8) }
private func fixture(dimensions: [UInt64] = [4], type: UInt32 = 0, offset: UInt64 = 0, duplicate: Bool = false, oversizedArray: Bool = false, payloadBytes: Int = 16) -> Data {
    var data = integer(UInt32(0x46554747)) + integer(UInt32(3)) + integer(UInt64(1))
    data += integer(UInt64(2 + (duplicate ? 1 : 0) + (oversizedArray ? 1 : 0)))
    data += string("general.architecture") + integer(UInt32(8)) + string("gemma3")
    data += string("general.file_type") + integer(UInt32(4)) + integer(UInt32(0))
    if duplicate { data += string("general.architecture") + integer(UInt32(8)) + string("other") }
    if oversizedArray { data += string("tokenizer.ggml.tokens") + integer(UInt32(9)) + integer(UInt32(8)) + integer(UInt64(1_000_001)) }
    data += string("test.weight") + integer(UInt32(dimensions.count))
    for dimension in dimensions { data += integer(dimension) }
    data += integer(type) + integer(offset)
    while !data.count.isMultiple(of: 32) { data.append(0) }
    data += Data(repeating: 0, count: payloadBytes)
    return data
}

@Suite("Bounded GGUF inspection")
struct GGUFInspectionTests {
    private func withFile<T>(_ data: Data, _ operation: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-gguf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.gguf")
        try data.write(to: file)
        return try operation(file)
    }

    @Test func readsATinyKnownTensorWithoutAllocatingWeights() throws {
        try withFile(fixture()) { file in
            let result = try GGUFInspection.inspect(file)
            #expect(result.architecture == "gemma3")
            #expect(result.quantizationType == 0)
            #expect(result.parameters == 4 && result.tensorCount == 1)
            #expect(result.tensorTypes == [0])
            #expect(result.fileBytes == result.headerBytes + 16)
        }
    }

    @Test func supportedHalfAndQuantizedBlockLayoutsHaveCompleteStorage() throws {
        let cases: [(UInt32, UInt64, Int)] = [(1, 8, 16), (12, 256, 144), (14, 256, 210)]
        for (type, elements, bytes) in cases {
            try withFile(fixture(dimensions: [elements], type: type, payloadBytes: bytes)) { file in
                let result = try GGUFInspection.inspect(file)
                #expect(result.parameters == elements && result.tensorTypes == [type])
                #expect(result.fileBytes - result.headerBytes == UInt64(bytes))
            }
            try withFile(fixture(dimensions: [elements], type: type, payloadBytes: bytes - 1)) { file in
                #expect(throws: ModelFormatError.self) { try GGUFInspection.inspect(file) }
            }
        }
    }

    @Test func malformedAndOverflowingHeadersNeverBecomeModels() throws {
        let invalid: [Data] = [
            Data(), Data("not a model".utf8), fixture().prefix(20),
            fixture(dimensions: []), fixture(dimensions: [0]), fixture(dimensions: [UInt64.max]),
            fixture(dimensions: [16_777_216, 16_777_216, 16_777_216, 16_777_216]),
            fixture(dimensions: [255], type: 12), fixture(type: 999),
            fixture(offset: 1), fixture(offset: 32), fixture(duplicate: true), fixture(oversizedArray: true),
        ]
        for data in invalid {
            try withFile(data) { file in #expect(throws: (any Error).self) { try GGUFInspection.inspect(file) } }
        }
    }

    @Test func fileAndStringBoundsRejectUnsafeIntake() throws {
        try withFile(fixture()) { file in
            #expect(throws: ModelFormatError.self) { try GGUFInspection.inspect(file, maximumFileBytes: 16) }
            let link = file.deletingLastPathComponent().appendingPathComponent("link.gguf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(throws: ModelFormatError.self) { try GGUFInspection.inspect(link) }
        }
        var hugeString = integer(UInt32(0x46554747)) + integer(UInt32(3)) + integer(UInt64(1)) + integer(UInt64(1))
        hugeString += integer(UInt64.max)
        try withFile(hugeString) { file in #expect(throws: ModelFormatError.self) { try GGUFInspection.inspect(file) } }
    }
}

private let nativeModelRoot = ProcessInfo.processInfo.environment["EARMARK_GGUF_INSPECTION_ROOT"]
@Suite("Actual GGUF checkpoint header inspection", .enabled(if: nativeModelRoot != nil))
struct RealGGUFInspectionTests {
    @Test func allFourTextProfilesHaveBoundedNativeLayouts() throws {
        let root = URL(fileURLWithPath: try #require(nativeModelRoot))
        let cases: [(String, String, ClosedRange<UInt64>)] = [
            ("hymt18-q4/Hy-MT2-1.8B-Q4_K_M.gguf", "hunyuan-dense", 1_000_000_000...2_500_000_000),
            ("hymt7-q4/Hy-MT2-7B-Q4_K_M.gguf", "hunyuan-dense", 5_000_000_000...9_000_000_000),
            ("gemma4-q4/translategemma-4b-it.Q4_K_M.gguf", "gemma3", 3_000_000_000...5_500_000_000),
            ("gemma12-q4/translategemma-12b-it.Q4_K_M.gguf", "gemma3", 9_000_000_000...14_000_000_000),
        ]
        for (file, architecture, parameters) in cases {
            let result = try GGUFInspection.inspect(root.appendingPathComponent(file))
            #expect(result.architecture == architecture)
            #expect(result.quantizationType == 15)
            #expect(parameters.contains(result.parameters))
            #expect(result.headerBytes < 64 * 1_024 * 1_024)
            #expect(result.tensorTypes == [0, 12, 14])
        }
    }
}
