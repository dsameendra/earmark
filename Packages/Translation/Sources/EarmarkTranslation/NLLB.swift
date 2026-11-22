import AppCore
import Foundation

/// FLORES-200 codes used by NLLB-200.
public enum NLLBLanguages {
    public static let codes: [LanguageCode: String] = [
        "si": "sin_Sinh", "en": "eng_Latn", "ta": "tam_Taml", "hi": "hin_Deva", "bn": "ben_Beng", "ur": "urd_Arab",
        "te": "tel_Telu", "ml": "mal_Mlym", "kn": "kan_Knda", "mr": "mar_Deva", "gu": "guj_Gujr", "pa": "pan_Guru", "ne": "npi_Deva",
        "de": "deu_Latn", "fr": "fra_Latn", "es": "spa_Latn", "it": "ita_Latn", "pt": "por_Latn", "nl": "nld_Latn", "ja": "jpn_Jpan",
        "ko": "kor_Hang", "zh": "zho_Hans", "ar": "arb_Arab", "ru": "rus_Cyrl", "id": "ind_Latn", "th": "tha_Thai", "vi": "vie_Latn",
    ]
    /// Languages the engine offers by default: the catalog set (si, en, ta, hi) plus bn and ur, which Apple lacks.
    public static let defaultLanguages: Set<LanguageCode> = ["si", "en", "ta", "hi", "bn", "ur"]
}

/// The inference part of NLLB (tokenise, beam-search decode, detokenise). Isolated so the engine is testable and so the runtime
/// can be swapped (see ``CTranslate2WorkerRuntime`` for the verified runtime and the notes on a shippable in-process one).
public protocol NLLBRuntime: Sendable {
    func load(modelFolder: URL) async throws
    /// `source` / `target` are FLORES codes such as `sin_Sinh`.
    func translate(_ texts: [String], source: String, target: String) async throws -> [String]
    func unload() async
}

/// NLLB-200 distilled 600M, user-downloaded through `ModelManaging` (CC-BY-NC-4.0, non-commercial build only).
public actor NLLBEngine: TranslationEngine, PairSupportChecking {
    public nonisolated var id: EngineID { TranslationEngineIDs.nllb }
    private let models: any ModelManaging
    private let runtime: any NLLBRuntime
    private let modelID: ModelID
    private let languages: Set<LanguageCode>
    private var loaded = false
    private let maxItems: Int
    private let maxCharacters: Int

    public init(
        models: any ModelManaging, runtime: any NLLBRuntime, modelID: ModelID = TranslationEngineIDs.nllbModel,
        languages: Set<LanguageCode> = NLLBLanguages.defaultLanguages, maxItems: Int = 8, maxCharacters: Int = 1_200
    ) {
        self.models = models
        self.runtime = runtime
        self.modelID = modelID
        self.languages = languages
        self.maxItems = maxItems
        self.maxCharacters = maxCharacters
    }

    public nonisolated static func isLowConfidence(to target: LanguageCode) -> Bool { target.primary == .sinhala }

    public func supports(_ pair: LanguagePair) async -> Bool {
        let (s, t) = (pair.source.primary, pair.target.primary)
        return s != t && languages.contains(s) && languages.contains(t) && NLLBLanguages.codes[s] != nil && NLLBLanguages.codes[t] != nil
    }

    public func supportedPairs() async -> Set<LanguagePair> {
        var pairs = Set<LanguagePair>()
        for a in languages { for b in languages where a != b { pairs.insert(LanguagePair(source: a, target: b)) } }
        return pairs
    }

    /// Drops the loaded model (one heavy model resident at a time, per the translation spec).
    public func unload() async {
        await runtime.unload()
        loaded = false
    }

    private func ensureLoaded() async throws {
        if loaded { return }
        guard case .installed = await models.state(of: modelID) else { throw AppError.modelNotInstalled(modelID) }
        let folder = try await models.location(of: modelID)
        do {
            try await runtime.load(modelFolder: folder)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.engineFailure(id, reason: error.localizedDescription)
        }
        loaded = true
    }

    private func run(_ texts: [String], from: LanguageCode, to: LanguageCode) async throws -> [String] {
        guard let src = NLLBLanguages.codes[from.primary] else { throw AppError.unsupportedLanguage(from) }
        guard let tgt = NLLBLanguages.codes[to.primary] else { throw AppError.unsupportedLanguage(to) }
        try await ensureLoaded()
        do {
            return try await runtime.translate(texts, source: src, target: tgt)
        } catch let error as AppError {
            throw error
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            throw AppError.engineFailure(id, reason: error.localizedDescription)
        }
    }

    public nonisolated func translate(
        items: [TranslationItem], from: LanguageCode, to: LanguageCode
    ) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        streamInBatches(
            items: items, maxItems: maxItems, maxCharacters: maxCharacters, engine: id,
            lowConfidence: Self.isLowConfidence(to: to)
        ) { texts in try await self.run(texts, from: from, to: to) }
    }
}

// MARK: - Runtime: CTranslate2 worker

/// Runs CTranslate2 + SentencePiece in a persistent Python worker (JSON lines over stdio).
///
/// Why: CTranslate2 and SentencePiece are C++ libraries with no Swift package, and there is no MLX or Core ML conversion of NLLB
/// (specs/research/translation.md section 6). This runtime is the verified path for development, measurement and non-sandboxed
/// builds: it needs `ctranslate2` and `sentencepiece` installed in the interpreter. A sandboxed, self-contained build must replace
/// it with an in-process runtime (libctranslate2 behind a C shim plus a Swift SentencePiece tokenizer) behind the same protocol.
public actor CTranslate2WorkerRuntime: NLLBRuntime {
    public static let workerScript = #"""
        import sys, json
        import ctranslate2, sentencepiece as spm
        d = sys.argv[1]
        threads = int(sys.argv[2]) if len(sys.argv) > 2 else 0
        tr = ctranslate2.Translator(d, device="cpu", compute_type="int8", intra_threads=threads)
        sp = spm.SentencePieceProcessor(model_file=d + "/sentencepiece.bpe.model")
        sys.stdout.write(json.dumps({"ready": True}) + "\n"); sys.stdout.flush()
        for line in sys.stdin:
            req = None
            try:
                req = json.loads(line)
                src, tgt, texts = req["src"], req["tgt"], req["texts"]
                toks = [[src] + sp.encode(t, out_type=str)[:500] + ["</s>"] for t in texts]
                res = tr.translate_batch(toks, target_prefix=[[tgt]] * len(toks), beam_size=4, max_decoding_length=256)
                out = [sp.decode(r.hypotheses[0][1:]) for r in res]
                sys.stdout.write(json.dumps({"id": req["id"], "out": out}, ensure_ascii=False) + "\n")
            except Exception as e:
                rid = req.get("id", -1) if isinstance(req, dict) else -1
                sys.stdout.write(json.dumps({"id": rid, "error": str(e)}) + "\n")
            sys.stdout.flush()
        """#

    private let python: URL
    private let threads: Int
    private var process: Process?
    private var stdin: FileHandle?
    private var lines: LineReader?
    private var nextID = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(pythonExecutable: URL, threads: Int = 0) {
        self.python = pythonExecutable
        self.threads = threads
    }

    public func load(modelFolder: URL) async throws {
        if process?.isRunning == true { return }
        let p = Process()
        p.executableURL = python
        p.arguments = ["-I", "-c", Self.workerScript, modelFolder.path, String(threads)]
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let buffer = LineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        let reader = LineReader(stream)
        guard let first = await reader.next(), first.contains("ready") else {
            p.terminate()
            process = nil
            throw AppError.engineFailure(TranslationEngineIDs.nllb, reason: "CTranslate2 worker failed to start (is ctranslate2 installed?).")
        }
        lines = reader
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        await acquire()
        defer { release() }
        guard process?.isRunning == true, let stdin, let reader = lines else {
            throw AppError.engineFailure(TranslationEngineIDs.nllb, reason: "CTranslate2 worker is not running.")
        }
        nextID += 1
        let id = nextID
        let payload: [String: Any] = ["id": id, "src": source, "tgt": target, "texts": texts]
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
        let reply = await reader.next()
        guard let reply, let obj = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else {
            throw AppError.engineFailure(TranslationEngineIDs.nllb, reason: "CTranslate2 worker closed unexpectedly.")
        }
        if let error = obj["error"] as? String { throw AppError.engineFailure(TranslationEngineIDs.nllb, reason: error) }
        guard let out = obj["out"] as? [String], out.count == texts.count else {
            throw AppError.engineFailure(TranslationEngineIDs.nllb, reason: "Malformed worker reply.")
        }
        return out
    }

    public func unload() async {
        if let process, process.isRunning {
            try? stdin?.close()
            process.terminate()
        }
        process = nil
        stdin = nil
        lines = nil
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var out: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            out.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return out
    }
}

/// Single-consumer line reader; callers are serialised by the runtime's gate.
private final class LineReader: @unchecked Sendable {
    private var iterator: AsyncStream<String>.Iterator
    init(_ stream: AsyncStream<String>) { iterator = stream.makeAsyncIterator() }
    func next() async -> String? { await iterator.next() }
}
