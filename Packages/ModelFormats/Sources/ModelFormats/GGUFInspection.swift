import Foundation

public struct ModelFormatError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Structural evidence only. Never loads weights, runs model code, or establishes
/// product compatibility, model identity, licence eligibility or translation quality.
public struct GGUFInspection: Sendable {
    public let architecture: String
    public let quantizationType: UInt32?
    public let parameters: UInt64
    public let tensorCount: Int
    public let tensorTypes: Set<UInt32>
    public let fileBytes: UInt64
    public let headerBytes: UInt64

    public static func inspect(_ file: URL, maximumFileBytes: UInt64 = 32 * 1_024 * 1_024 * 1_024) throws -> Self {
        guard file.isFileURL, !file.path.utf8.contains(0) else { throw ModelFormatError("Choose a local GGUF file.") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0,
              UInt64(size) <= maximumFileBytes else { throw ModelFormatError("The GGUF file is unsafe, empty or exceeds this profile's size limit.") }
        let reader = try Cursor(file: file, fileBytes: UInt64(size))
        guard try reader.u32() == 0x46554747 else { throw ModelFormatError("This file is not GGUF.") }
        let version = try reader.u32()
        guard version == 2 || version == 3 else { throw ModelFormatError("Use a supported GGUF v2 or v3 file.") }
        let count = try reader.u64()
        let metadataCount = try reader.u64()
        guard (1...100_000).contains(count), metadataCount <= 100_000 else { throw ModelFormatError("The GGUF header has invalid tensor or metadata counts.") }
        var architecture: String?
        var quantization: UInt32?
        var alignment: UInt64 = 32
        var keys = Set<String>()
        for _ in 0..<metadataCount {
            let key = try reader.string(maximum: 1_024)
            guard keys.insert(key).inserted else { throw ModelFormatError("The GGUF header has duplicate metadata keys.") }
            let type = try reader.u32()
            switch key {
            case "general.architecture":
                guard type == 8 else { throw ModelFormatError("The GGUF architecture field is malformed.") }
                architecture = try reader.string(maximum: 128)
            case "general.file_type", "general.alignment":
                guard type == 4 else { throw ModelFormatError("The GGUF quantization or alignment field is malformed.") }
                let value = try reader.u32()
                if key == "general.file_type" { quantization = value } else { alignment = UInt64(value) }
            default: try reader.skipValue(type)
            }
        }
        guard let architecture, !architecture.isEmpty,
              alignment > 0, alignment <= 4_096, alignment & (alignment - 1) == 0 else {
            throw ModelFormatError("The GGUF architecture or alignment is invalid.")
        }
        var parameters: UInt64 = 0
        var types = Set<UInt32>()
        var names = Set<String>()
        var tensors: [(offset: UInt64, bytes: UInt64)] = []
        tensors.reserveCapacity(Int(count))
        for _ in 0..<count {
            let name = try reader.string(maximum: 1_024)
            guard !name.isEmpty, names.insert(name).inserted else { throw ModelFormatError("The GGUF tensor names are empty or duplicated.") }
            let dimensions = try reader.u32()
            guard (1...4).contains(dimensions) else { throw ModelFormatError("Unsupported GGUF tensor dimensions.") }
            var elements: UInt64 = 1
            var firstDimension: UInt64 = 0
            for dimension in 0..<dimensions {
                let length = try reader.u64()
                guard length > 0, length <= 16_777_216 else { throw ModelFormatError("The GGUF tensor shape exceeds the supported bounds.") }
                if dimension == 0 { firstDimension = length }
                elements = try checkedMultiply(elements, length)
            }
            parameters = try checkedAdd(parameters, elements)
            guard parameters <= 1_000_000_000_000 else { throw ModelFormatError("The GGUF parameter count exceeds the supported bound.") }
            let type = try reader.u32()
            types.insert(type)
            let (block, bytes) = try storage(type)
            guard firstDimension.isMultiple(of: block) else { throw ModelFormatError("The quantized tensor row is not a complete block.") }
            let storageBytes = try checkedMultiply(elements / block, bytes)
            let offset = try reader.u64()
            guard offset.isMultiple(of: alignment) else { throw ModelFormatError("The GGUF tensor offset is not aligned.") }
            tensors.append((offset, storageBytes))
        }
        let aligned = try checkedAdd(reader.position, alignment - 1) & ~(alignment - 1)
        guard aligned <= UInt64(size) else { throw ModelFormatError("The GGUF tensor data is missing.") }
        let available = UInt64(size) - aligned
        for tensor in tensors {
            guard tensor.offset <= available, tensor.bytes <= available - tensor.offset else {
                throw ModelFormatError("A GGUF tensor extends beyond the actual file.")
            }
        }
        return Self(architecture: architecture, quantizationType: quantization, parameters: parameters, tensorCount: Int(count),
                    tensorTypes: types, fileBytes: UInt64(size), headerBytes: aligned)
    }

    private static func checkedMultiply(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (value, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else { throw ModelFormatError("The GGUF tensor size overflowed.") }
        return value
    }
    private static func checkedAdd(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw ModelFormatError("The GGUF byte or parameter count overflowed.") }
        return value
    }

    /// Block layouts from the pinned ggml definitions. Unknown formats are not
    /// guessed; extending this table requires a reviewed layout and real fixture.
    private static func storage(_ type: UInt32) throws -> (UInt64, UInt64) {
        switch type {
        case 0: (1, 4) // F32
        case 1: (1, 2) // F16
        case 12: (256, 144) // Q4_K
        case 14: (256, 210) // Q6_K
        default: throw ModelFormatError("This GGUF tensor quantization is not supported by the validated inspector.")
        }
    }
}

/// At most 64 KiB buffered, 64 MiB of header address space, and bounded metadata
/// element counts. Skips do not allocate or read ignored arrays/string contents.
private final class Cursor {
    private let file: FileHandle
    private let fileBytes: UInt64
    private var buffer = Data()
    private var index = 0
    private(set) var position: UInt64 = 0
    init(file: URL, fileBytes: UInt64) throws { self.file = try FileHandle(forReadingFrom: file); self.fileBytes = fileBytes }
    deinit { try? file.close() }
    private func check(_ bytes: UInt64) throws {
        guard position <= 64 * 1_024 * 1_024, bytes <= 64 * 1_024 * 1_024 - position,
              position <= fileBytes, bytes <= fileBytes - position else { throw ModelFormatError("The GGUF header is truncated or exceeds its read bound.") }
    }
    private func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let bytes = MemoryLayout<T>.size
        try check(UInt64(bytes))
        if buffer.count - index < bytes {
            try file.seek(toOffset: position)
            buffer = try file.read(upToCount: 65_536) ?? Data()
            index = 0
        }
        guard buffer.count - index >= bytes else { throw ModelFormatError("The GGUF header ended unexpectedly.") }
        let value = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index, as: T.self) }
        index += bytes; position += UInt64(bytes)
        return T(littleEndian: value)
    }
    func u32() throws -> UInt32 { try integer(UInt32.self) }
    func u64() throws -> UInt64 { try integer(UInt64.self) }
    func skip(_ bytes: UInt64) throws {
        try check(bytes)
        if bytes <= UInt64(buffer.count - index) { index += Int(bytes) }
        else { buffer.removeAll(keepingCapacity: true); index = 0; try file.seek(toOffset: position + bytes) }
        position += bytes
    }
    func string(maximum: Int) throws -> String {
        let bytes = try u64()
        guard bytes <= UInt64(maximum) else { throw ModelFormatError("A GGUF header string exceeds its bound.") }
        try check(bytes)
        var data = Data()
        data.reserveCapacity(Int(bytes))
        var remaining = Int(bytes)
        while remaining > 0 {
            if index == buffer.count {
                try file.seek(toOffset: position)
                buffer = try file.read(upToCount: 65_536) ?? Data(); index = 0
            }
            let count = min(remaining, buffer.count - index)
            guard count > 0 else { throw ModelFormatError("The GGUF string ended unexpectedly.") }
            data.append(buffer[index..<(index + count)])
            index += count; position += UInt64(count); remaining -= count
        }
        guard let value = String(data: data, encoding: .utf8), !value.utf8.contains(0) else { throw ModelFormatError("A GGUF header string is not valid text.") }
        return value
    }
    func skipValue(_ type: UInt32) throws {
        switch type {
        case 0, 1, 7: try skip(1)
        case 2, 3: try skip(2)
        case 4, 5, 6: try skip(4)
        case 10, 11, 12: try skip(8)
        case 8:
            let count = try u64()
            guard count <= 1_048_576 else { throw ModelFormatError("A GGUF metadata string is oversized.") }
            try skip(count)
        case 9:
            let element = try u32()
            let count = try u64()
            guard count <= 1_000_000, element != 9 else { throw ModelFormatError("A GGUF metadata array exceeds the supported bound.") }
            // Validate even a zero-length array's element type.
            guard (0...12).contains(element), element != 9 else { throw ModelFormatError("Unsupported GGUF metadata array type.") }
            for _ in 0..<count { try skipValue(element) }
        default: throw ModelFormatError("Unsupported GGUF metadata type.")
        }
    }
}
