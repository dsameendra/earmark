import AppCore
import Foundation

/// Compact, lossless binary encoding of `[Word]` used for the `segment.words` column.
///
/// Layout (little endian): `version:u8`, `count:varint`, then per word
/// `utf8Length:varint`, `utf8 bytes`, `start:f64`, `end:f64`, `hasConfidence:u8`, `[confidence:f64]`.
/// Roughly 3x smaller than JSON and much faster to decode.
public enum WordBlob {
    static let version: UInt8 = 1

    /// Encodes words into a compact blob.
    public static func encode(_ words: [Word]) -> Data {
        var out = Data()
        out.reserveCapacity(2 + words.count * 24)
        out.append(version)
        appendVarint(UInt64(words.count), to: &out)
        for word in words {
            let utf8 = Array(word.text.utf8)
            appendVarint(UInt64(utf8.count), to: &out)
            out.append(contentsOf: utf8)
            appendDouble(word.start, to: &out)
            appendDouble(word.end, to: &out)
            if let confidence = word.confidence {
                out.append(1)
                appendDouble(confidence, to: &out)
            } else {
                out.append(0)
            }
        }
        return out
    }

    /// Decodes a blob produced by ``encode(_:)``.
    /// - Throws: `AppError.persistence` when the blob is truncated or has an unknown version.
    public static func decode(_ data: Data) throws -> [Word] {
        let bytes = [UInt8](data)
        guard bytes.first == version else { throw AppError.persistence(reason: "Corrupt word blob") }
        var cursor = 1
        let count = try readVarint(bytes, &cursor)
        var words: [Word] = []
        words.reserveCapacity(Int(min(count, 1 << 20)))
        for _ in 0..<count {
            let length = Int(try readVarint(bytes, &cursor))
            guard cursor + length <= bytes.count else { throw AppError.persistence(reason: "Corrupt word blob") }
            let text = String(bytes: bytes[cursor..<cursor + length], encoding: .utf8) ?? ""
            cursor += length
            let start = try readDouble(bytes, &cursor)
            let end = try readDouble(bytes, &cursor)
            guard cursor < bytes.count else { throw AppError.persistence(reason: "Corrupt word blob") }
            let flag = bytes[cursor]
            cursor += 1
            let confidence = flag == 1 ? try readDouble(bytes, &cursor) : nil
            words.append(Word(text: text, start: start, end: end, confidence: confidence))
        }
        return words
    }

    private static func appendVarint(_ value: UInt64, to out: inout Data) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    private static func appendDouble(_ value: Double, to out: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
    }

    private static func readVarint(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < bytes.count, shift < 64 {
            let byte = bytes[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw AppError.persistence(reason: "Corrupt word blob")
    }

    private static func readDouble(_ bytes: [UInt8], _ cursor: inout Int) throws -> Double {
        guard cursor + 8 <= bytes.count else { throw AppError.persistence(reason: "Corrupt word blob") }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(bytes[cursor + i]) << (8 * UInt64(i)) }
        cursor += 8
        return Double(bitPattern: bits)
    }
}
