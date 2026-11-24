import Darwin
import Foundation

/// Owns one isolated model/session. The engine must keep a session lease from begin through finish;
/// this transport additionally serializes commands and cancels only the admitted request's child.
public actor SpeechWorkerClient {
    private let executable: URL
    private let timeout: Duration
    private let gate = SpeechOperationGate()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: SpeechReplyReader?
    private var modelFile: URL?
    private var profile: String?
    private var readiness: SpeechWorkerReady?
    private var nextID: UInt64 = 0

    public init(executable: URL, timeout: Duration = .seconds(180)) {
        self.executable = executable; self.timeout = timeout
    }

    deinit {
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        if let process { Self.terminate(process) }
    }

    public func start(modelFile: URL, profile: String) async throws -> SpeechWorkerReady {
        try await gate.withLease { try await self.startLocked(modelFile: modelFile, profile: profile) }
    }

    public func send(_ request: SpeechWorkerRequest) async throws -> SpeechWorkerReply {
        try await gate.withLease { try await self.sendLocked(request) }
    }

    public func stop() async {
        await gate.cleanup { await self.stopLocked() }
    }

    private func startLocked(modelFile: URL, profile: String) async throws -> SpeechWorkerReady {
        try Task.checkCancellation()
        if self.modelFile == modelFile, self.profile == profile, process?.isRunning == true, let readiness { return readiness }
        stopLocked()
        guard executable.isFileURL, modelFile.isFileURL else { throw SpeechWireError.invalid("Native workers and models must be local files.") }
        let child = Process()
        child.executableURL = executable
        child.arguments = [modelFile.path, profile]
        // Do not inherit inference overrides or dynamic-loader injections from a development shell.
        child.environment = ["PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let buffer = SpeechReplyBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; continuation.finish(); return }
            do {
                for line in try buffer.append(bytes) {
                    if case .dropped = continuation.yield(line) {
                        handle.readabilityHandler = nil
                        continuation.finish(throwing: SpeechWireError.invalid("Unsolicited native speech responses."))
                    }
                }
            } catch {
                handle.readabilityHandler = nil
                continuation.finish(throwing: error)
            }
        }
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        reader = SpeechReplyReader(stream)
        do {
            try child.run()
            let reply = try await exchange(data: nil, expectedID: 0)
            guard let ready = reply.ready, ready.nativeVersion == "0.4.2", ready.architecture == "parakeet",
                  ready.variant == "multitalker-parakeet-streaming-0.6b-v1" else {
                throw SpeechWireError.invalid("The speech helper loaded an unexpected native profile.")
            }
            self.modelFile = modelFile; self.profile = profile; readiness = ready; nextID = 0
            return ready
        } catch { stopLocked(); if Task.isCancelled { throw CancellationError() }; throw error }
    }

    private func sendLocked(_ original: SpeechWorkerRequest) async throws -> SpeechWorkerReply {
        try Task.checkCancellation()
        guard readiness != nil, process?.isRunning == true else { throw SpeechWireError.invalid("The speech worker is not loaded.") }
        nextID += 1
        var request = original
        request.id = nextID
        var bytes = try JSONEncoder().encode(request)
        guard bytes.count <= SpeechWire.maximumMessageBytes else { throw SpeechWireError.invalid("Speech request exceeded message limit.") }
        bytes.append(10)
        do { return try await exchange(data: bytes, expectedID: request.id) }
        catch { stopLocked(); if Task.isCancelled { throw CancellationError() }; throw error }
    }

    private func exchange(data: Data?, expectedID: UInt64) async throws -> SpeechWorkerReply {
        guard let child = process, let input, let reader else { throw SpeechWireError.invalid("The speech worker is not loaded.") }
        let timeout = timeout
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            Self.terminate(child)
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let data {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { try input.write(contentsOf: data); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }
            let bytes = try await reader.next()
            try Task.checkCancellation()
            guard let bytes else { throw SpeechWireError.invalid("The speech worker closed or timed out.") }
            let reply = try JSONDecoder().decode(SpeechWorkerReply.self, from: bytes)
            guard reply.version == SpeechWire.version, reply.id == expectedID else { throw SpeechWireError.invalid("Mismatched speech worker reply.") }
            if let error = reply.error { throw SpeechWireError.invalid(error) }
            return reply
        } onCancel: { Self.terminate(child) }
    }

    private func stopLocked() {
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        if let process { Self.terminate(process) }
        process = nil; input = nil; output = nil; reader = nil
        modelFile = nil; profile = nil; readiness = nil
    }

    private nonisolated static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // A child stuck in native compute must not survive cancellation indefinitely.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private final class SpeechReplyBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    func append(_ bytes: Data) throws -> [Data] {
        lock.lock(); defer { lock.unlock() }
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard !line.isEmpty, line.count <= SpeechWire.maximumMessageBytes else { throw SpeechWireError.invalid("Invalid speech response size.") }
            lines.append(line)
        }
        guard pending.count <= SpeechWire.maximumMessageBytes else { throw SpeechWireError.invalid("Oversized speech response.") }
        return lines
    }
}

/// One consumer, protected by the client's FIFO admission gate.
private final class SpeechReplyReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, any Error>.Iterator
    init(_ stream: AsyncThrowingStream<Data, any Error>) { iterator = stream.makeAsyncIterator() }
    func next() async throws -> Data? { try await iterator.next() }
}
