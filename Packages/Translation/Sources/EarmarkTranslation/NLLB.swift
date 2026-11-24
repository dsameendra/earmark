import AppCore
import Foundation
import NativeWorkerKit
import TextModelProfiles

/// FLORES-200 codes used by NLLB-200.
public enum NLLBLanguages {
    public static let codes: [LanguageCode: String] = [
        "si": "sin_Sinh", "en": "eng_Latn", "ta": "tam_Taml", "hi": "hin_Deva", "bn": "ben_Beng", "ur": "urd_Arab",
        "te": "tel_Telu", "ml": "mal_Mlym", "kn": "kan_Knda", "mr": "mar_Deva", "gu": "guj_Gujr", "pa": "pan_Guru", "ne": "npi_Deva",
        "de": "deu_Latn", "fr": "fra_Latn", "es": "spa_Latn", "it": "ita_Latn", "pt": "por_Latn", "nl": "nld_Latn", "ja": "jpn_Jpan",
        "ko": "kor_Hang", "zh": "zho_Hans", "ar": "arb_Arab", "ru": "rus_Cyrl", "id": "ind_Latn", "th": "tha_Thai", "vi": "vie_Latn",
    ]
    /// Every currently mapped language is available; licensing and installed-model checks still apply.
    public static let defaultLanguages: Set<LanguageCode> = Set(codes.keys)

    /// Region normalization is valid only for the FLORES writing system this
    /// build actually maps. Never turn Traditional Chinese into Simplified.
    public static func code(for language: LanguageCode) -> String? {
        if let code = codes[language] { return code }
        guard let code = codes[language.primary], let script = code.split(separator: "_").last else { return nil }
        let identity = language.translationIdentity.rawValue.split(separator: "-")
        if identity.count > 1, identity[1] != script { return nil }
        return code
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
        self.languages = languages
        self.maxItems = maxItems
        self.maxCharacters = maxCharacters
    }

    public nonisolated static func isLowConfidence(to target: LanguageCode) -> Bool { target.primary == .sinhala }

    public func supports(_ pair: LanguagePair) async -> Bool {
        let (s, t) = (pair.source.primary, pair.target.primary)
        guard let source = NLLBLanguages.code(for: pair.source), let target = NLLBLanguages.code(for: pair.target) else { return false }
        return source != target && languages.contains(s) && languages.contains(t)
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
        guard let src = NLLBLanguages.code(for: from), languages.contains(from.primary) else { throw AppError.unsupportedLanguage(from) }
        guard let tgt = NLLBLanguages.code(for: to), languages.contains(to.primary) else { throw AppError.unsupportedLanguage(to) }
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
    private let threads: Int
    private let timeout: Duration
    private let gate = TranslationOperationGate()
    private var modelFolder: URL?
    private var transport: WorkerTransport?
    private var nextID = 0

    public init(pythonExecutable: URL, threads: Int = 0) {
        executable = pythonExecutable; isNative = false; profile = "nllb"; engineID = TranslationEngineIDs.nllb
        self.threads = max(1, min(threads == 0 ? 4 : threads, 64)); timeout = .seconds(120)
    }

    public init(nativeExecutable: URL, threads: Int = 4, profile: CTranslate2ModelProfile = .nllb, requestTimeout: Duration = .seconds(120)) {
        executable = nativeExecutable; isNative = true; self.profile = profile.rawValue; engineID = EngineID(profile.rawValue)
        self.threads = max(1, min(threads, 64)); timeout = requestTimeout
    }

    public init(nativeExecutable: URL, generativeProfile: GenerativeProfile, threads: Int = 4, requestTimeout: Duration = .seconds(120)) {
        executable = nativeExecutable; isNative = true; profile = generativeProfile.rawValue
        engineID = GenerativeTranslationEngine.engineID(for: generativeProfile)
        self.threads = max(1, min(threads, 64)); timeout = requestTimeout
    }

    public func load(modelFolder: URL) async throws {
        try await gate.withLease { try await self.loadLocked(modelFolder) }
    }

    private func loadLocked(_ folder: URL) async throws {
        try Task.checkCancellation()
        guard folder.isFileURL else { throw AppError.other("Translation models must be local folders.") }
        if modelFolder != folder { await stopWorker() }
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
        struct Ready: Decodable { let ready: Bool?; let profile: String?; let error: String? }
        let value = try JSONDecoder().decode(Ready.self, from: first)
        if let error = value.error { throw AppError.engineFailure(engineID, reason: error) }
        guard value.ready == true, !isNative || value.profile == profile else {
            throw AppError.engineFailure(engineID, reason: "The translation worker could not load the selected model profile.")
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

    public func unload() async {
        await gate.cleanup {
            await self.stopWorker()
            await self.clearFolder()
        }
    }

    private func clearFolder() { modelFolder = nil }

    private func stopWorker() async {
        await transport?.stop()
        transport = nil
    }
}
