import Darwin
import Foundation

/// Bounded byte framing that scans only newly received bytes, including split UTF-8 JSON.
public struct WorkerLineFramer: Sendable {
    private var pending = Data()
    private var scanned = 0
    public init() {}
    public var hasPartialMessage: Bool { !pending.isEmpty }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= WorkerTransport.maximumMessageBytes + 1 else {
            throw WorkerTransportError.invalid("Oversized worker read.")
        }
        pending.append(bytes)
        var lines: [Data] = []
        while let offset = nextNewline() {
            guard offset > 0, offset <= WorkerTransport.maximumMessageBytes else {
                throw WorkerTransportError.invalid("Invalid worker message size.")
            }
            guard lines.count < 32 else { throw WorkerTransportError.invalid("Too many worker messages in one read.") }
            let newline = pending.startIndex + offset
            lines.append(Data(pending[..<newline]))
            pending.removeSubrange(...newline)
            scanned = 0
        }
        scanned = pending.count
        guard pending.count <= WorkerTransport.maximumMessageBytes else {
            throw WorkerTransportError.invalid("Oversized worker response.")
        }
        return lines
    }

    private func nextNewline() -> Int? {
        pending.withUnsafeBytes { bytes -> Int? in
            guard scanned < bytes.count, let base = bytes.baseAddress,
                  let found = memchr(base.advanced(by: scanned), 10, bytes.count - scanned) else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
    }
}
