import Darwin
import Foundation

/// Synchronous bounded stdin for serial native helpers. POSIX reads return the
/// available bytes rather than waiting to fill an entire pipe read request.
public enum WorkerInput {
    public static func forEachLine(_ body: (Data) throws -> Void) throws {
        var framer = WorkerLineFramer()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw WorkerTransportError.invalid("Could not read the worker input pipe.") }
            if count == 0 { break }
            for line in try framer.append(Data(chunk.prefix(count))) { try body(line) }
        }
        guard !framer.hasPartialMessage else { throw WorkerTransportError.invalid("Incomplete worker request at end of input.") }
    }
}
