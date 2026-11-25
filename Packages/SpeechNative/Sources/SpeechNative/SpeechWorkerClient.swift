import Foundation
import NativeWorkerKit

/// Owns one isolated model/session. The engine must keep a session lease from begin through finish;
/// this transport additionally serializes commands and cancels only the admitted request's child.
public actor SpeechWorkerClient: WorkerStopping {
    private let executable: URL
    private let timeout: Duration
    private let gate = SpeechOperationGate()
    private var transport: WorkerTransport?
    private var modelFile: URL?
    private var profile: String?
    private var readiness: SpeechWorkerReady?
    private var nextID: UInt64 = 0

    public init(executable: URL, timeout: Duration = .seconds(180)) {
        self.executable = executable; self.timeout = timeout
    }

    public func start(modelFile: URL, profile: String) async throws -> SpeechWorkerReady {
        try await gate.withLease { try await self.startLocked(modelFile: modelFile, profile: profile) }
    }

    public func send(_ request: SpeechWorkerRequest) async throws -> SpeechWorkerReply {
        try await gate.withLease { try await self.sendLocked(request) }
    }

    @discardableResult
    public func stop() async -> Bool {
        await gate.cleanup { await self.stopLocked() }
    }

    private func startLocked(modelFile: URL, profile: String) async throws -> SpeechWorkerReady {
        try Task.checkCancellation()
        guard let selected = NativeSpeechProfile(rawValue: profile) else {
            throw SpeechWireError.invalid("Unsupported native speech profile.")
        }
        if self.modelFile == modelFile, self.profile == profile, let transport,
           await transport.isRunning(), let readiness { return readiness }
        guard await stopLocked() else { throw SpeechWireError.invalid("The previous speech worker has not stopped. Try again after it exits.") }
        guard executable.isFileURL, modelFile.isFileURL else { throw SpeechWireError.invalid("Native workers and models must be local files.") }
        let channel = WorkerTransport(executable: executable, arguments: [modelFile.path, profile], timeout: timeout)
        transport = channel
        do {
            let reply = try decode(await channel.start(), expectedID: 0)
            guard let ready = reply.ready, ready.nativeVersion == "0.4.2",
                  selected.matches(architecture: ready.architecture, variant: ready.variant),
                  Set(ready.languages) == Set(selected.languages),
                  Set(ready.translationTargets) == Set(selected.translationTargets),
                  ready.canTranslate == !selected.translationTargets.isEmpty,
                  ready.canStream == selected.canStream, ready.canDetectLanguage == selected.canDetectLanguage,
                  ready.canDiarize == selected.canDiarize, !ready.canStreamWithSpeakers else {
                throw SpeechWireError.invalid("The speech helper loaded an unexpected native profile.")
            }
            self.modelFile = modelFile; self.profile = profile; readiness = ready; nextID = 0
            return ready
        } catch { await stopLocked(); if Task.isCancelled { throw CancellationError() }; throw mapped(error) }
    }

    private func sendLocked(_ original: SpeechWorkerRequest) async throws -> SpeechWorkerReply {
        try Task.checkCancellation()
        guard readiness != nil, let transport else { throw SpeechWireError.invalid("The speech worker is not loaded.") }
        if let pcm = original.pcm {
            let limit = original.operation == .feed ? SpeechWire.maximumFrameSamples : SpeechWire.maximumRunSamples
            guard pcm.count <= limit * MemoryLayout<Float>.size else {
                throw SpeechWireError.invalid("Speech PCM exceeded the operation's sample limit.")
            }
        }
        nextID += 1
        var request = original
        request.id = nextID
        let bytes = try JSONEncoder().encode(request)
        guard bytes.count <= SpeechWire.maximumMessageBytes else { throw SpeechWireError.invalid("Speech request exceeded message limit.") }
        do {
            let reply = try decode(await transport.request(bytes), expectedID: request.id)
            let expectsSnapshot = [.run, .feed, .finish].contains(request.operation)
            guard reply.ready == nil, (reply.snapshot != nil) == expectsSnapshot else {
                throw SpeechWireError.invalid("Unexpected speech response payload.")
            }
            return reply
        }
        catch { await stopLocked(); if Task.isCancelled { throw CancellationError() }; throw mapped(error) }
    }

    private func decode(_ bytes: Data, expectedID: UInt64) throws -> SpeechWorkerReply {
        let reply = try JSONDecoder().decode(SpeechWorkerReply.self, from: bytes)
        guard reply.version == SpeechWire.version, reply.id == expectedID else { throw SpeechWireError.invalid("Mismatched speech worker reply.") }
        if let error = reply.error { throw SpeechWireError.invalid(error) }
        return reply
    }

    private func mapped(_ error: any Error) -> any Error {
        if case WorkerTransportError.invalid(let reason) = error {
            return SpeechWireError.invalid(reason.replacingOccurrences(of: "worker response", with: "speech response"))
        }
        return error
    }

    @discardableResult
    private func stopLocked() async -> Bool {
        modelFile = nil; profile = nil; readiness = nil
        guard let transport else { return true }
        let stopped = await transport.stop()
        if stopped { self.transport = nil }
        return stopped
    }
}
