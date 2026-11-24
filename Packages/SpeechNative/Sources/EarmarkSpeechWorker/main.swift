import Darwin
import Foundation
import SpeechNative
import TranscribeCpp

/// Native handles live only in this synchronous, single-session child process.
final class SpeechWorker {
    let model: Model
    let session: Session
    let capabilities: Capabilities
    var stream: TranscribeCpp.Stream?
    var receivedSamples = 0
    var lastID: UInt64 = 0

    init(path: String, profile: String, backend: Backend) throws {
        // Finite profiles are activated only after architecture-specific native validation.
        guard profile == "multitalker-v1" else { throw SpeechWireError.invalid("Unsupported native speech profile.") }
        model = try Model(path: path, options: ModelOptions(backend: backend))
        guard model.arch == "parakeet", model.variant == "multitalker-parakeet-streaming-0.6b-v1" else {
            throw SpeechWireError.invalid("The model does not match the selected speech profile.")
        }
        capabilities = try model.capabilities
        guard capabilities.nativeSampleRate == 16_000 else { throw SpeechWireError.invalid("Unsupported native sample rate.") }
        session = try model.session(SessionOptions(nThreads: 4))
    }

    var ready: SpeechWorkerReady {
        SpeechWorkerReady(
            architecture: model.arch, variant: model.variant, backend: model.backend, languages: capabilities.languages,
            translationTargets: capabilities.translateTargetLanguages, canDetectLanguage: capabilities.supportsLanguageDetect,
            canStream: capabilities.supportsStreaming, canTranslate: capabilities.supportsTranslate,
            canDiarize: model.supports(.diarization), canStreamWithSpeakers: false, nativeVersion: Transcribe.version())
    }

    func options(_ request: SpeechWorkerRequest) throws -> RunOptions {
        var language = request.language
        if language == nil, !capabilities.supportsLanguageDetect {
            guard capabilities.languages.count == 1 else { throw SpeechWireError.invalid("Choose a supported source language.") }
            language = capabilities.languages.first
        }
        if let language, !capabilities.languages.isEmpty, !capabilities.languages.contains(language) {
            throw SpeechWireError.invalid("Unsupported source language.")
        }
        if let target = request.targetLanguage {
            guard capabilities.supportsTranslate, capabilities.translateTargetLanguages.contains(target) else {
                throw SpeechWireError.invalid("Unsupported speech translation target.")
            }
        }
        if request.diarize == true, !model.supports(.diarization) {
            throw SpeechWireError.invalid("This checkpoint has no integrated speaker support.")
        }
        return RunOptions(task: request.targetLanguage == nil ? .transcribe : .translate, timestamps: .auto,
                          diarize: request.diarize == true ? .on : .off, language: language, targetLanguage: request.targetLanguage)
    }

    func respond(_ request: SpeechWorkerRequest) throws -> SpeechWorkerReply {
        guard request.id > lastID else { throw SpeechWireError.invalid("Request IDs must increase.") }
        lastID = request.id
        switch request.operation {
        case .begin:
            guard stream == nil, request.pcm == nil, capabilities.supportsStreaming else {
                throw SpeechWireError.invalid("Cannot begin this stream.")
            }
            // Upstream 0.4.2 accepts this flag but only warns and decodes one speaker.
            // Never turn that silent downgrade into an advertised overlap stream.
            guard request.diarize != true else {
                throw SpeechWireError.invalid("This native profile supports speaker-attributed files, but its streaming API cannot yet transcribe overlapping speakers.")
            }
            stream = try session.stream(options(request))
            receivedSamples = 0
            return SpeechWorkerReply(id: request.id)
        case .feed:
            guard let stream, let data = request.pcm else { throw SpeechWireError.invalid("No active stream or PCM frame.") }
            try rejectOptions(request)
            let frame = try SpeechWire.decodePCM(data, maximumSamples: SpeechWire.maximumFrameSamples)
            guard receivedSamples + frame.count <= SpeechWire.maximumSessionSamples else {
                throw SpeechWireError.invalid("The speech session reached its duration limit.")
            }
            let update = try stream.feed(frame)
            receivedSamples += frame.count
            return SpeechWorkerReply(id: request.id, snapshot: try snapshot(stream.snapshot, stream: stream, update: update))
        case .finish:
            guard let current = stream, request.pcm == nil else { throw SpeechWireError.invalid("No active stream to finish.") }
            try rejectOptions(request)
            let update = try current.finalize()
            guard !session.wasTruncated, !session.wasAborted else { throw SpeechWireError.invalid("Native speech did not complete.") }
            let result = try snapshot(current.snapshot, stream: current, update: update)
            stream = nil
            return SpeechWorkerReply(id: request.id, snapshot: result)
        case .reset:
            guard request.pcm == nil else { throw SpeechWireError.invalid("Reset cannot contain audio.") }
            try rejectOptions(request)
            stream?.reset(); stream = nil; receivedSamples = 0
            return SpeechWorkerReply(id: request.id)
        case .run:
            guard stream == nil, let data = request.pcm else { throw SpeechWireError.invalid("Cannot run during an active stream.") }
            let frame = try SpeechWire.decodePCM(data, maximumSamples: SpeechWire.maximumRunSamples)
            let result = try session.run(frame, options: options(request))
            guard !session.wasTruncated, !session.wasAborted else { throw SpeechWireError.invalid("Native speech did not complete.") }
            receivedSamples = frame.count
            return SpeechWorkerReply(id: request.id, snapshot: try snapshot(result, stream: nil, update: nil))
        }
    }

    private func rejectOptions(_ request: SpeechWorkerRequest) throws {
        guard request.language == nil, request.targetLanguage == nil, request.diarize == nil else {
            throw SpeechWireError.invalid("Set language and speaker options when beginning the stream.")
        }
    }

    private func snapshot(_ result: Transcript, stream: TranscribeCpp.Stream?, update: StreamUpdate?) throws -> SpeechNativeSnapshot {
        guard result.segments.count <= SpeechWire.maximumRows, result.words.count <= SpeechWire.maximumRows,
              result.speakerSegments.count <= SpeechWire.maximumRows else { throw SpeechWireError.invalid("Native output exceeded row limits.") }
        let counts = stream == nil ? (segments: result.segments.count, words: result.words.count) : session.earmarkCommittedCounts()
        guard (0...result.segments.count).contains(counts.segments), (0...result.words.count).contains(counts.words) else {
            throw SpeechWireError.invalid("Invalid native committed-row counts.")
        }
        let segments = result.segments.map {
            SpeechNativeSegment(startMS: $0.t0Ms, endMS: $0.t1Ms, text: $0.text, speaker: $0.speakerId,
                                firstWord: $0.firstWord, wordCount: $0.nWords)
        }
        let words = result.words.map {
            SpeechNativeWord(startMS: $0.t0Ms, endMS: $0.t1Ms, text: $0.text, segmentIndex: $0.segIndex)
        }
        let turns = result.speakerSegments.map { SpeechNativeSpeakerTurn(startMS: $0.t0Ms, endMS: $0.t1Ms, speaker: $0.speakerId) }
        let kind = SpeechNativeTimestampKind(rawValue: String(describing: result.timestampKind)) ?? .unknown
        return SpeechNativeSnapshot(
            timestampKind: kind, text: result.text, committedText: stream?.text.committed ?? result.text, tentativeText: stream?.text.tentative ?? "",
            language: result.language, revision: update?.revision ?? 0, isFinal: update?.isFinal ?? true,
            inputReceivedMS: update?.inputReceivedMs ?? Int64(receivedSamples / 16),
            audioCommittedMS: update?.audioCommittedMs ?? Int64(receivedSamples / 16), bufferedMS: update?.bufferedMs ?? 0,
            committedSegments: counts.segments, committedWords: counts.words, segments: segments, words: words, speakerTurns: turns)
    }
}

func write(_ reply: SpeechWorkerReply) throws {
    var bytes = try JSONEncoder().encode(reply)
    guard bytes.count <= SpeechWire.maximumMessageBytes else { throw SpeechWireError.invalid("Native response exceeded message limit.") }
    bytes.append(10)
    try FileHandle.standardOutput.write(contentsOf: bytes)
}

func runWorker() throws {
    let args = CommandLine.arguments
    guard args.count == 3 || args.count == 4 else { throw SpeechWireError.invalid("Expected model path and supported profile.") }
    Transcribe.disableLogging()
    let backend: Backend
    switch args.count == 4 ? args[3] : "auto" {
    case "auto": backend = .auto
    case "cpu": backend = .cpu
    case "metal": backend = .metal
    default: throw SpeechWireError.invalid("Unsupported speech backend.")
    }
    let worker = try SpeechWorker(path: args[1], profile: args[2], backend: backend)
    try write(SpeechWorkerReply(id: 0, ready: worker.ready))
    var framer = SpeechLineFramer()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        // FileHandle.read(upToCount:) may wait to fill a pipe read. POSIX read returns
        // available bytes, allowing short request/response messages to make progress.
        let count = chunk.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw SpeechWireError.invalid("Could not read the speech request pipe.") }
        if count == 0 { break }
        for line in try framer.append(Data(chunk.prefix(count))) {
            let request = try JSONDecoder().decode(SpeechWorkerRequest.self, from: line)
            do { try write(worker.respond(request)) }
            catch {
                worker.stream?.reset(); worker.stream = nil
                try write(SpeechWorkerReply(id: request.id, error: error.localizedDescription))
            }
        }
    }
    guard !framer.hasPartialMessage else { throw SpeechWireError.invalid("Incomplete request at end of input.") }
}

do { try runWorker() }
catch {
    try? write(SpeechWorkerReply(id: 0, error: error.localizedDescription))
    exit(1)
}
