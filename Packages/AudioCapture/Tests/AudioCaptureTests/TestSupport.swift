import Darwin
import Foundation

/// Resolves files under the repository's `fixtures/` directory. Audio fixtures are gitignored, so a git worktree may not
/// contain them. Resolution order: `$EARMARK_FIXTURES_DIR`, then every `fixtures/` directory found walking upward from this
/// source file (a worktree under `<repo>/.claude/worktrees/x` therefore finds `<repo>/fixtures`). Returns `nil` when absent
/// so tests can skip gracefully.
enum Fixtures {
    static func url(_ relativePath: String, filePath: String = #filePath) -> URL? {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["EARMARK_FIXTURES_DIR"] { roots.append(URL(fileURLWithPath: env)) }
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.path != "/" {
            roots.append(dir.appendingPathComponent("fixtures"))
            dir = dir.deletingLastPathComponent()
        }
        return roots.map { $0.appendingPathComponent(relativePath) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Writes a 16-bit PCM mono WAV with a sine tone, streaming in blocks so long files do not need memory.
func writeSineWAV(to url: URL, seconds: Double, sampleRate: Int, frequency: Double = 440, amplitude: Double = 0.5) throws {
    let total = Int(seconds * Double(sampleRate))
    let dataBytes = total * 2
    var header = Data()
    func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
    func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
    header.append(contentsOf: Array("RIFF".utf8))
    put32(UInt32(36 + dataBytes))
    header.append(contentsOf: Array("WAVEfmt ".utf8))
    put32(16)
    put16(1)
    put16(1)
    put32(UInt32(sampleRate))
    put32(UInt32(sampleRate * 2))
    put16(2)
    put16(16)
    header.append(contentsOf: Array("data".utf8))
    put32(UInt32(dataBytes))
    FileManager.default.createFile(atPath: url.path, contents: header)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    var index = 0
    let block = 1 << 16
    while index < total {
        let count = min(block, total - index)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = Int16(amplitude * 32767 * sin(2 * Double.pi * frequency * Double(index + i) / Double(sampleRate)))
        }
        try handle.write(contentsOf: samples.withUnsafeBytes { Data($0) })
        index += count
    }
}

/// Current resident memory of this process in bytes.
func residentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
