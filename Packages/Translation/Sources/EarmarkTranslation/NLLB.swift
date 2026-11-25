import AppCore
import Foundation
import NativeWorkerKit
import ModelLanguageProfiles
import TextModelProfiles

/// FLORES-200 codes used by NLLB-200.
public enum NLLBLanguages {
    public static let codes: [LanguageCode: String] = Dictionary(uniqueKeysWithValues: NLLBLanguageProfile.codes.map { (LanguageCode($0.key), $0.value) })
    public static let aliases: [LanguageCode: LanguageCode] = Dictionary(uniqueKeysWithValues: NLLBLanguageProfile.aliases.map { (LanguageCode($0.key), LanguageCode($0.value)) })
    /// Tokenizer-supported execution remains experimental, with directional
    /// quality acceptance recorded separately from the inventory.
    public static let defaultLanguages: Set<LanguageCode> = Set(codes.keys)

    public static func canonical(for language: LanguageCode) -> LanguageCode? {
        for candidate in [language, language.translationIdentity] {
            if codes[candidate] != nil { return candidate }
            if let canonical = aliases[candidate], codes[canonical] != nil { return canonical }
        }
        return nil
    }

    public static func code(for language: LanguageCode) -> String? {
        canonical(for: language).flatMap { codes[$0] }
    }
}

/// The inference part of NLLB (tokenise, beam-search decode, detokenise). Isolated so the engine is testable and so the runtime
/// can be swapped (see ``CTranslate2WorkerRuntime`` for the verified runtime and the notes on a shippable in-process one).
public protocol NLLBRuntime: Sendable {
    func load(modelFolder: URL) async throws
    /// Tags follow the configured runtime profile: FLORES for NLLB, target codes
    /// for MADLAD, or the validated fixed pair for Marian.
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
    private let gate = TranslationOperationGate()
    private let maxItems: Int
    private let maxCharacters: Int

    public init(
        models: any ModelManaging, runtime: any NLLBRuntime, modelID: ModelID = TranslationEngineIDs.nllbModel,
        languages: Set<LanguageCode> = NLLBLanguages.defaultLanguages, maxItems: Int = 8, maxCharacters: Int = 1_200
    ) {
        self.models = models
        self.runtime = runtime
        self.modelID = modelID
        self.languages = Set(languages.compactMap { NLLBLanguages.canonical(for: $0) })
        self.maxItems = maxItems
        self.maxCharacters = maxCharacters
    }

    public nonisolated static func isLowConfidence(to target: LanguageCode) -> Bool { target.primary == .sinhala }

    public func supports(_ pair: LanguagePair) async -> Bool {
        guard let source = NLLBLanguages.canonical(for: pair.source), let target = NLLBLanguages.canonical(for: pair.target) else { return false }
        return source != target && languages.contains(source) && languages.contains(target)
    }

    public func supportedPairs() async -> Set<LanguagePair> {
        var pairs = Set<LanguagePair>()
        for a in languages { for b in languages where a != b { pairs.insert(LanguagePair(source: a, target: b)) } }
        return pairs
    }

    /// Drops the loaded model (one heavy model resident at a time, per the translation spec).
    public func unload() async {
        await gate.cleanup { await self.unloadLocked() }
    }

    private func unloadLocked() async {
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
        try await gate.withLease { try await self.runLocked(texts, from: from, to: to) }
    }

    private func runLocked(_ texts: [String], from: LanguageCode, to: LanguageCode) async throws -> [String] {
        guard let source = NLLBLanguages.canonical(for: from), languages.contains(source), let src = NLLBLanguages.codes[source] else { throw AppError.unsupportedLanguage(from) }
        guard let target = NLLBLanguages.canonical(for: to), languages.contains(target), let tgt = NLLBLanguages.codes[target] else { throw AppError.unsupportedLanguage(to) }
        guard src != tgt else { throw TranslationFailure.sameLanguage(from) }
        try Task.checkCancellation()
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

/// Runs CTranslate2 + SentencePiece in a persistent native or development Python worker (JSON lines over stdio).
///
/// The shipping backend launches the bundled Swift/C++ helper, which owns CTranslate2 and SentencePiece.
/// A Python reference backend is retained for explicit Debug development overrides and parity checks.
/// Both use the same serial JSON-lines protocol; cancellation terminates the helper to release inference promptly.
public enum CTranslate2ModelProfile: String, Sendable { case nllb, madlad, marian }

public actor CTranslate2WorkerRuntime: NLLBRuntime, WorkerStopping {
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
                pieces = [sp.encode(t, out_type=str) for t in texts]
                if any(len(t) > 500 for t in pieces):
                    raise ValueError("Text exceeds this model's input limit; split it into shorter segments")
                toks = [[src] + t + ["</s>"] for t in pieces]
                res = tr.translate_batch(toks, target_prefix=[[tgt]] * len(toks), beam_size=4, max_decoding_length=256)
                if any(len(r.hypotheses[0]) >= 256 for r in res):
                    raise ValueError("Translation reached the decoding limit; split the source into shorter segments")
                out = [sp.decode(r.hypotheses[0][1:]) for r in res]
                sys.stdout.write(json.dumps({"id": req["id"], "out": out}, ensure_ascii=False) + "\n")
            except Exception as e:
                rid = req.get("id", -1) if isinstance(req, dict) else -1
                sys.stdout.write(json.dumps({"id": rid, "error": str(e)}) + "\n")
            sys.stdout.flush()
        """#

    private let executable: URL
    private let isNative: Bool
    private let profile: String
    private let engineID: EngineID
    private let generativeProfile: GenerativeProfile?
    private let threads: Int
    private let timeout: Duration
    private let gate = TranslationOperationGate()
    private var modelFolder: URL?
    private var transport: WorkerTransport?
    private var nextID = 0

    public init(pythonExecutable: URL, threads: Int = 0) {
        executable = pythonExecutable; isNative = false; profile = "nllb"; engineID = TranslationEngineIDs.nllb; generativeProfile = nil
        self.threads = max(1, min(threads == 0 ? 4 : threads, 64)); timeout = .seconds(120)
    }

    public init(nativeExecutable: URL, threads: Int = 4, profile: CTranslate2ModelProfile = .nllb, requestTimeout: Duration = .seconds(120)) {
        executable = nativeExecutable; isNative = true; self.profile = profile.rawValue; engineID = EngineID(profile.rawValue); generativeProfile = nil
        self.threads = max(1, min(threads, 64)); timeout = requestTimeout
    }

    public init(nativeExecutable: URL, generativeProfile: GenerativeProfile, threads: Int = 4, requestTimeout: Duration = .seconds(120)) {
        executable = nativeExecutable; isNative = true; profile = generativeProfile.rawValue
        engineID = GenerativeTranslationEngine.engineID(for: generativeProfile)
        self.generativeProfile = generativeProfile
        self.threads = max(1, min(threads, 64)); timeout = requestTimeout
    }

    func workerProcessIdentifier() async -> Int32? { await transport?.processIdentifier() }

    public func load(modelFolder: URL) async throws {
        try await gate.withLease { try await self.loadLocked(modelFolder) }
    }

    private func loadLocked(_ folder: URL) async throws {
        try Task.checkCancellation()
        guard folder.isFileURL else { throw AppError.other("Translation models must be local folders.") }
        if modelFolder != folder, await !stopWorker() {
            throw AppError.engineFailure(engineID, reason: "The previous translation worker has not stopped. Try again after it exits.")
        }
        modelFolder = folder
        do { try await startWorker() }
        catch { await stopWorker(); throw error }
    }

    private func startWorker() async throws {
        guard let modelFolder else { throw AppError.other("Load a translation model before translating.") }
        if transport == nil {
            let arguments = isNative ? [modelFolder.path, String(threads), profile]
                : ["-I", "-c", Self.workerScript, modelFolder.path, String(threads)]
            transport = WorkerTransport(executable: executable, arguments: arguments, timeout: timeout)
            nextID = 0
        }
        guard let transport else { throw AppError.other("The translation worker is unavailable.") }
        let first = try await transport.start()
        struct Ready: Decodable {
            let ready: Bool?; let profile: String?; let error: String?
            let tokenizerOnly: Bool?; let architecture: String?; let parameters: UInt64?; let quantizationType: UInt32?
        }
        let value = try JSONDecoder().decode(Ready.self, from: first)
        if let error = value.error { throw AppError.engineFailure(engineID, reason: error) }
        guard value.ready == true, !isNative || value.profile == profile else {
            throw AppError.engineFailure(engineID, reason: "The translation worker could not load the selected model profile.")
        }
        if let generativeProfile {
            guard value.tokenizerOnly == false, value.architecture == generativeProfile.architecture,
                  let parameters = value.parameters, generativeProfile.parameterRange.contains(parameters), value.quantizationType == 15 else {
                throw AppError.engineFailure(engineID, reason: "The native translation worker did not load the selected inference variant and quantization.")
            }
        }
    }

    public func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        try await gate.withLease { try await self.translateLocked(texts, source: source, target: target) }
    }

    private func translateLocked(_ texts: [String], source: String, target: String) async throws -> [String] {
        try Task.checkCancellation()
        guard texts.count <= 8, texts.allSatisfy({ $0.utf8.count <= 100_000 && !$0.utf8.contains(0) }),
              !source.isEmpty, !target.isEmpty, source.utf8.count <= 128, target.utf8.count <= 128,
              !source.utf8.contains(0), !target.utf8.contains(0) else {
            throw AppError.other("Translation input exceeded the supported batch or language limits.")
        }
        if texts.isEmpty { return [] }
        do {
            try await startWorker()
            guard let transport else { throw AppError.other("The translation worker is unavailable.") }
            nextID += 1
            let id = nextID
            let payload: [String: Any] = ["id": id, "src": source, "tgt": target, "texts": texts]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let reply = try await transport.request(data)
            try Task.checkCancellation()
            struct Reply: Decodable { let id: Int; let error: String?; let out: [String]? }
            let object = try JSONDecoder().decode(Reply.self, from: reply)
            guard object.id == id else {
                throw AppError.engineFailure(engineID, reason: "Malformed translation worker reply.")
            }
            if let error = object.error { throw AppError.engineFailure(engineID, reason: error) }
            guard let output = object.out, output.count == texts.count,
                  output.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AppError.engineFailure(engineID, reason: "Malformed translation worker output.")
            }
            return output
        } catch {
            await stopWorker()
            throw error
        }
    }

    public func unload() async { _ = await stop() }

    @discardableResult
    public func stop() async -> Bool {
        await gate.cleanup { await self.unloadLocked() }
    }

    private func unloadLocked() async -> Bool {
        let stopped = await stopWorker()
        if stopped { modelFolder = nil }
        return stopped
    }

    @discardableResult
    private func stopWorker() async -> Bool {
        guard let transport else { return true }
        let stopped = await transport.stop()
        if stopped { self.transport = nil }
        return stopped
    }
}
