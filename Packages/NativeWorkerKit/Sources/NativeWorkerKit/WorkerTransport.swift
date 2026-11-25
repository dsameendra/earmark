import Darwin
import Foundation

public enum WorkerTransportError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let reason): reason } }
}

/// One local child, one outstanding JSON-line operation. Payload interpretation
/// and session ownership belong to the caller; this layer bounds bytes/lifetime.
/// `false` retains ownership: a resource manager must not admit a replacement.
public protocol WorkerStopping: Sendable {
    @discardableResult func stop() async -> Bool
}

public actor WorkerTransport: WorkerStopping {
    public static let maximumMessageBytes = 4 * 1_024 * 1_024
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let timeout: Duration
    private let startupTimeout: Duration
    private let gate = WorkerGate()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: ReplyReader?
    private var handshake: Data?

    public init(executable: URL, arguments: [String], environment: [String: String] = ["PATH": "/usr/bin:/bin"], timeout: Duration = .seconds(120), startupTimeout: Duration = .seconds(30)) {
        self.executable = executable; self.arguments = arguments
        self.environment = environment; self.timeout = timeout; self.startupTimeout = startupTimeout
    }

    deinit {
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        if let process { Self.terminate(process) }
    }

    /// Diagnostic identity of the owned live child; never used to control unrelated processes.
    public func processIdentifier() -> Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    public func isRunning() -> Bool { process?.isRunning == true && handshake != nil }

    public func start() async throws -> Data {
        try await gate.withLease { try await self.startLocked() }
    }

    public func request(_ data: Data) async throws -> Data {
        try await gate.withLease { try await self.requestLocked(data) }
    }

    @discardableResult
    public func stop() async -> Bool {
        await gate.cleanup { await self.stopLocked() }
    }

    private func startLocked() async throws -> Data {
        try Task.checkCancellation()
        if process?.isRunning == true, let handshake { return handshake }
        guard await stopLocked() else { throw WorkerTransportError.invalid("The previous worker has not stopped.") }
        guard executable.isFileURL else { throw WorkerTransportError.invalid("Workers must be local executables.") }
        let child = Process()
        child.executableURL = executable; child.arguments = arguments; child.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let buffer = ReplyBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; continuation.finish(); return }
            do {
                for line in try buffer.append(bytes) {
                    if case .dropped = continuation.yield(line) {
                        handle.readabilityHandler = nil
                        continuation.finish(throwing: WorkerTransportError.invalid("Unsolicited worker responses."))
                    }
                }
            } catch {
                handle.readabilityHandler = nil
                continuation.finish(throwing: error)
            }
        }
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        reader = ReplyReader(stream)
        do {
            try child.run()
            let first = try await exchange(nil, timeout: startupTimeout)
            handshake = first
            return first
        } catch {
            _ = await stopLocked()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func requestLocked(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= Self.maximumMessageBytes, !data.contains(10) else {
            throw WorkerTransportError.invalid("Invalid worker request size or framing.")
        }
        guard handshake != nil, process?.isRunning == true else { throw WorkerTransportError.invalid("The worker is not loaded.") }
        do { return try await exchange(data + Data([10]), timeout: timeout) }
        catch {
            _ = await stopLocked()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// The same deadline covers the background pipe write and the response read.
    private func exchange(_ data: Data?, timeout: Duration) async throws -> Data {
        guard let child = process, let input, let reader else { throw WorkerTransportError.invalid("The worker is not loaded.") }
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
            guard let bytes else { throw WorkerTransportError.invalid("The worker closed or timed out.") }
            return bytes
        } onCancel: { Self.terminate(child) }
    }

    private func stopLocked() async -> Bool {
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil; reader = nil; handshake = nil
        guard let child = process else { return true }
        Self.terminate(child)
        // Releasing the old model is part of switching, including a cancelled
        // caller's cleanup. Do not launch a replacement while it is still alive.
        let stopped = await Task.detached {
            let deadline = ContinuousClock.now + .seconds(3)
            while child.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return !child.isRunning
        }.value
        if stopped { process = nil }
        return stopped
    }

    private nonisolated static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private final class ReplyBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var framer = WorkerLineFramer()
    func append(_ bytes: Data) throws -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return try framer.append(bytes)
    }
}

private final class ReplyReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, any Error>.Iterator
    init(_ stream: AsyncThrowingStream<Data, any Error>) { iterator = stream.makeAsyncIterator() }
    func next() async throws -> Data? { try await iterator.next() }
}
